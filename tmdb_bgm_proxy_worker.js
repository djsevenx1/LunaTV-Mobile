// TMDB + Bangumi + GitHub 统一代理 Worker
// 路由:
//   /movie/..., /tv/..., /search/...  → TMDB API  (api.themoviedb.org/3)
//   /image/...                        → TMDB 图片 (image.tmdb.org)
//   /bangumi/...                      → Bangumi API (api.bgm.tv), 透传客户端 Authorization
//   /bgm-img/...                      → Bangumi 图片 (lain.bgm.tv), 自动补 Referer
//   /github/repos/{owner}/{repo}/releases/latest
//                                      → GitHub Releases API (api.github.com), 用于 app 内检查更新
//   /github/asset/{owner}/{repo}/{tag}/{asset}
//                                      → GitHub release asset 下载, 跟随 302 跳到
//                                        objects.githubusercontent.com, 流式转发, 用于 app
//                                        内建下载器拿 APK. 解决国内 GFW.
// 环境变量 (在 Cloudflare Dashboard / wrangler secret 配):
//   TMDB_API_KEY       必需  TMDB API key
//   BGM_ACCESS_TOKEN   可选  Bangumi access_token, 缺省时透传客户端 Authorization header
//   GITHUB_TOKEN       可选  GitHub PAT, 拉高 60/hr 匿名 → 5000/hr 认证. 缺省走匿名 (60/hr, 检查更新够用, 下载走 asset 路由)

export default {
  async fetch(request, env, ctx) {
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, HEAD, POST, OPTIONS',
      'Access-Control-Allow-Headers': '*',
    }
    // 预检请求
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders })
    }
    try {
      const url = new URL(request.url)

      // Bangumi 图片代理 (优先匹配, 避免和 /image 冲突)
      if (url.pathname.startsWith('/bgm-img/')) {
        return await handleBgmImage(request, url, corsHeaders)
      }

      // Bangumi API 代理
      if (url.pathname.startsWith('/bangumi/')) {
        return await handleBgmApi(request, url, env, corsHeaders)
      }

      // GitHub release asset 下载 (app 内建下载器用)
      // 必须优先于 /image/ 匹配, 避免被当 TMDB image 路径处理
      if (url.pathname.startsWith('/github/asset/')) {
        return await handleGithubAsset(request, url, corsHeaders)
      }

      // GitHub Releases API (app 检查更新用)
      if (url.pathname.startsWith('/github/repos/')) {
        return await handleGithubApi(request, url, env, corsHeaders)
      }

      // TMDB 图片代理
      if (url.pathname.startsWith('/image/')) {
        return await handleTmdbImage(request, url, corsHeaders)
      }

      // 兜底: TMDB API 代理
      return await handleTmdbApi(request, url, env, corsHeaders)
    } catch (error) {
      return new Response(JSON.stringify({
        error: 'Proxy error',
        message: error.message
      }), {
        status: 500,
        headers: { 'Content-Type': 'application/json', ...corsHeaders }
      })
    }
  }
}

// ===== TMDB 图片代理 (image.tmdb.org) =====
async function handleTmdbImage(request, url, corsHeaders) {
  // 格式: /image/t/p/w500/abc.jpg 或 /image/w500/abc.jpg
  const imagePath = url.pathname.replace('/image', '')
  if (!imagePath) {
    return jsonError('Image path required', 400, corsHeaders)
  }
  const imageUrl = `https://image.tmdb.org${imagePath}`
  const response = await fetch(imageUrl)
  if (!response.ok) {
    return jsonError('Image not found', response.status, corsHeaders, { url: imageUrl })
  }
  const contentType = response.headers.get('content-type') || 'image/jpeg'
  const buf = await response.arrayBuffer()
  return new Response(buf, {
    status: response.status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400', // 缓存 1 天
      ...corsHeaders,
    }
  })
}

// ===== TMDB API 代理 (api.themoviedb.org/3) =====
async function handleTmdbApi(request, url, env, corsHeaders) {
  let apiPath = url.pathname
  // 兼容旧版 /proxy 前缀
  if (apiPath.startsWith('/proxy')) {
    apiPath = apiPath.replace('/proxy', '')
  }
  const searchParams = new URLSearchParams(url.searchParams)
  if (env.TMDB_API_KEY) {
    searchParams.set('api_key', env.TMDB_API_KEY)
  } else {
    return jsonError('TMDB API key not configured', 500, corsHeaders)
  }
  const apiUrl = `https://api.themoviedb.org/3${apiPath}?${searchParams}`
  const response = await fetch(apiUrl, {
    method: request.method,
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    }
  })
  return withCors(response, corsHeaders)
}

// ===== Bangumi API 代理 (api.bgm.tv) =====
// 透传客户端 Authorization (如果有), 否则尝试用 env.BGM_ACCESS_TOKEN.
// 强制 UA 满足 api.bgm.tv v0 API 的 "App/Version (URL)" 格式要求.
async function handleBgmApi(request, url, env, corsHeaders) {
  // /bangumi/v0/subject/123  →  https://api.bgm.tv/v0/subject/123
  const apiPath = url.pathname.replace('/bangumi', '')
  const searchParams = new URLSearchParams(url.searchParams)
  const apiUrl = `https://api.bgm.tv${apiPath}?${searchParams}`

  const headers = new Headers(request.headers)
  // 强制 UA: api.bgm.tv 拒绝浏览器 UA (返 400)
  if (!headers.has('User-Agent')) {
    headers.set('User-Agent', 'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)')
  }
  // 服务端持有 access_token 时, 注入 Bearer (缺省透传客户端)
  if (env.BGM_ACCESS_TOKEN && !headers.has('Authorization')) {
    headers.set('Authorization', `Bearer ${env.BGM_ACCESS_TOKEN}`)
  }
  // 透传方法, body 也透传
  const init = {
    method: request.method,
    headers,
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = await request.arrayBuffer()
  }

  const response = await fetch(apiUrl, init)
  return withCors(response, corsHeaders)
}

// ===== Bangumi 图片代理 (lain.bgm.tv) =====
// lain.bgm.tv 校验 Referer, 必须带 https://bgm.tv/
async function handleBgmImage(request, url, corsHeaders) {
  // /bgm-img/r/400/.../abc.jpg  →  https://lain.bgm.tv/r/400/.../abc.jpg
  const imagePath = url.pathname.replace('/bgm-img', '')
  if (!imagePath) {
    return jsonError('Image path required', 400, corsHeaders)
  }
  const imageUrl = `https://lain.bgm.tv${imagePath}`
  const response = await fetch(imageUrl, {
    headers: {
      'Referer': 'https://bgm.tv/',
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    }
  })
  if (!response.ok) {
    return jsonError('Image not found', response.status, corsHeaders, { url: imageUrl })
  }
  const contentType = response.headers.get('content-type') || 'image/jpeg'
  const buf = await response.arrayBuffer()
  return new Response(buf, {
    status: response.status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400', // 缓存 1 天
      ...corsHeaders,
    }
  })
}

// ===== 工具函数 =====
function withCors(response, corsHeaders) {
  const modified = new Response(response.body, response)
  for (const [k, v] of Object.entries(corsHeaders)) {
    modified.headers.set(k, v)
  }
  return modified
}

function jsonError(error, status, corsHeaders, extra = {}) {
  return new Response(JSON.stringify({ error, ...extra }), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders }
  })
}

// ===== GitHub Releases API 代理 (api.github.com) =====
//
// 格式: GET /github/repos/{owner}/{repo}/releases/latest
//   → https://api.github.com/repos/{owner}/{repo}/releases/latest
// 任意 path-based 调用: GET /github/repos/{owner}/{repo}/{path...}
//   → https://api.github.com/repos/{owner}/{repo}/{path...}
//
// 头:
//   - Accept: application/vnd.github.v3+json (api.github.com 要求)
//   - User-Agent: GitHub API 强制要求非空 UA, 否则 403
//   - Authorization: Bearer <GITHUB_TOKEN> (env 配了的话, 拉高 60→5000 req/hr)
//
// 设计: 走 worker 代理解决国内 GFW. app 检查更新只拉 1 次 latest,
//   匿名 60 req/hr 够用; 想拉高在 CF Dashboard 配 GITHUB_TOKEN secret.
//
// 为什么不放客户端直接调 worker 然后 worker 反代 api.github.com:
//   - 国内直连 api.github.com 100% 不可达 (GFW)
//   - 走 worker 反代 + CORS 头, app 端不用任何特殊处理
async function handleGithubApi(request, url, env, corsHeaders) {
  // /github/repos/{owner}/{repo}/releases/latest
  //   → https://api.github.com/repos/{owner}/{repo}/releases/latest
  const apiPath = url.pathname.replace('/github', '')
  const apiUrl = `https://api.github.com${apiPath}${url.search}`
  const headers = {
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'LunaTV-Mobile-Worker',
  }
  if (env.GITHUB_TOKEN) {
    headers['Authorization'] = `Bearer ${env.GITHUB_TOKEN}`
  }
  let response
  try {
    response = await fetch(apiUrl, {
      method: request.method,
      headers,
    })
  } catch (e) {
    return jsonError('GitHub API upstream unreachable', 502, corsHeaders,
      { url: apiUrl, message: e.message })
  }
  return withCors(response, corsHeaders)
}

// ===== GitHub release asset 下载代理 =====
//
// 格式: GET /github/asset/{owner}/{repo}/{tag}/{asset_name}
//   → https://github.com/{owner}/{repo}/releases/download/{tag}/{asset_name}
//   (跟 302 跳到 https://objects.githubusercontent.com/... 流式转发)
//
// 用途: app 内建下载器用. 直接下 GitHub release asset 国内 GFW
//   完全不可达, 走 worker 反代 + 流式转发, 跟用户代理浏览器下
//   一样效果, 但 app 内可以画进度条 / 调起 APK 安装器.
//
// 注意: stream body 不能用 withCors 包 (Response 二次构造 body
//   会 buffer 到内存, 几十 MB APK 直接爆). 走原始 response, 用
//   mutable headers 手动加 CORS.
async function handleGithubAsset(request, url, corsHeaders) {
  // /github/asset/{owner}/{repo}/{tag}/{asset_name}
  //   → https://github.com/{owner}/{repo}/releases/download/{tag}/{asset_name}
  const match = url.pathname.match(/^\/github\/asset\/([^/]+)\/([^/]+)\/([^/]+)\/(.+)$/)
  if (!match) {
    return jsonError('Invalid asset path. Expected /github/asset/{owner}/{repo}/{tag}/{asset_name}', 400, corsHeaders)
  }
  const [, owner, repo, tag, asset] = match
  const downloadUrl = `https://github.com/${owner}/${repo}/releases/download/${tag}/${asset}`

  // 跟 302 跳到 objects.githubusercontent.com (CF 走 stream)
  // GitHub release download 会 302 到 objects.githubusercontent.com,
  // fetch 默认 redirect='follow', 自动跟.
  let response
  try {
    response = await fetch(downloadUrl, {
      method: request.method,
      headers: {
        'User-Agent': 'LunaTV-Mobile-Worker',
        'Accept': 'application/octet-stream',
      },
      redirect: 'follow',
    })
  } catch (e) {
    return jsonError('GitHub asset upstream unreachable', 502, corsHeaders,
      { url: downloadUrl, message: e.message })
  }
  if (!response.ok) {
    return jsonError('GitHub asset fetch failed', response.status, corsHeaders,
      { url: downloadUrl, status: response.status })
  }

  // 原始 body 直接传 (不二次构造, 避免 buffer)
  // 手动补 CORS 头 (Response.headers immutable 时 clone() 再改)
  const newHeaders = new Headers(response.headers)
  for (const [k, v] of Object.entries(corsHeaders)) {
    newHeaders.set(k, v)
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  })
}
