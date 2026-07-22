// TMDB + Bangumi + GitHub 统一代理 Worker (在原 tmdb-proxy 基础上扩展)
// 路由:
//   /                                  → 主页 (LunaTV 风格说明页)
//   /health                            → 健康检查
//   /movie/..., /tv/..., /search/...   → TMDB API  (api.themoviedb.org/3)
//   /image/...                         → TMDB 图片 (image.tmdb.org)
//   /bangumi/...                       → Bangumi API (api.bgm.tv), 透传客户端 Authorization
//   /bgm-img/...                       → Bangumi 图片 (lain.bgm.tv), 自动补 Referer
//   /github/repos/{owner}/{repo}/releases/latest
//                                      → GitHub Releases API (api.github.com), 用于 app 内检查更新
//   /github/asset/{owner}/{repo}/{tag}/{asset}
//                                      → GitHub release asset 下载, 跟随 302 跳到
//                                        objects.githubusercontent.com, 流式转发, 用于 app
//                                        内建下载器拿 APK. 解决国内 GFW.
// 环境变量 (在 Cloudflare Dashboard / wrangler secret 配):
//   TMDB_API_KEY       必需  TMDB API key
//   BGM_ACCESS_TOKEN   可选  Bangumi access_token, 缺省时透传客户端 Authorization header
//   GITHUB_TOKEN       可选  GitHub PAT, 拉高 60/hr 匿名 → 5000/hr 认证. 缺省走匿名 (60/hr, 检查更新够用)

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

      // 主页 (LunaTV 风格)
      if (url.pathname === '/' || url.pathname === '') {
        return handleHomePage(url.origin)
      }

      // 健康检查
      if (url.pathname === '/health') {
        return new Response('OK', { status: 200, headers: corsHeaders })
      }

      // 短剧图片代理 (任意域名图床, 用 ?url= 传完整原 URL)
      if (url.pathname === '/sd-img') {
        return await handleShortDramaImage(request, url, corsHeaders)
      }

      // 短剧 TVBox API 代理 (path-based source key)
      if (url.pathname.startsWith('/sd-api/')) {
        return await handleShortDramaApi(request, url, corsHeaders)
      }

      // Bangumi 图片代理 (优先匹配, 避免和 /image 冲突)
      if (url.pathname.startsWith('/bgm-img/')) {
        return await handleBgmImage(request, url, corsHeaders)
      }

      // Bangumi API 代理
      if (url.pathname.startsWith('/bangumi/')) {
        return await handleBgmApi(request, url, env, corsHeaders)
      }

      // v2.1.46 fix: GitHub asset 代理 (app 内建下载器下 APK 用) —
      //   必须在 /github/ 通用路由之前匹配, 避免 asset path 被通用
      //   路由吞掉 (asset 路径是 /github/asset/owner/repo/tag/asset,
      //   跟 /github/repos/.../releases/latest 形态不同, 单独 handler
      //   做 302 跳 objects.githubusercontent.com 流式转发).
      // v2.1.49 改: 之前 v2.1.46 commit 漏了这 2 个路由分发块, 只
      //   加了 handleGithubApi / handleGithubAsset 函数定义, fetch
      //   handler 里没 if 调它们, 导致 /github/... 全部落到兜底
      //   handleTmdbApi 报 "TMDB API key not configured". 修.
      if (url.pathname.startsWith('/github/asset/')) {
        return await handleGithubAsset(request, url, corsHeaders)
      }

      // v2.1.46 fix: GitHub Releases API 代理 (app 检查更新用)
      if (url.pathname.startsWith('/github/')) {
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
  // 优先级: env.TMDB_API_KEY (服务端持有, 推荐) > 客户端 ?api_key= (透传)
  //
  // v2.1.40.1 改: 之前只认 env, 配了 Pages 没用的话整个 TMDB API 都 500.
  //   现在支持客户端 query string 传 api_key, 适合 "自己 fork 随便玩"
  //   不想去 CF Dashboard 配 env 的场景. 安全性: LunaTV 反正要 TMDB key
  //   才能用 (直连 api.themoviedb.org 也得带), 透传 HTTPS, 跟直连一样安全.
  const userKey = searchParams.get('api_key')
  if (env.TMDB_API_KEY) {
    searchParams.set('api_key', env.TMDB_API_KEY)
  } else if (userKey) {
    // 客户端传过来, 透传 (LunaTV 本来就有用户的 key, 走 worker 只是换个 host)
    searchParams.set('api_key', userKey)
  } else {
    return jsonError(
      'TMDB API key not configured (set Pages env TMDB_API_KEY, or pass ?api_key=xxx)',
      500,
      corsHeaders
    )
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

// ===== 主页 (LunaTV 风格: 深色 + 绿主色 #22C55E) =====
function handleHomePage(currentOrigin) {
  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>TMDBG - TMDB + Bangumi 代理</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    :root {
      --luna-green: #22C55E;
      --luna-green-deep: #10B981;
      --bg: #0F1117;
      --card: #1F2937;
      --border: #374151;
      --text: #FFFFFF;
      --sub: #9ca3af;
      --muted: #6b7280;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', 'Microsoft YaHei', Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      line-height: 1.6;
      padding: 24px 16px;
    }
    .container { max-width: 880px; margin: 0 auto; }
    .topbar {
      display: flex; align-items: center; gap: 8px;
      padding: 4px 4px 24px 4px;
    }
    .logo {
      width: 28px; height: 28px; border-radius: 6px;
      background: linear-gradient(135deg, var(--luna-green), var(--luna-green-deep));
      display: flex; align-items: center; justify-content: center;
      font-weight: 800; color: #052e16; font-size: 12px;
    }
    .brand { font-size: 16px; font-weight: 700; color: var(--text); }
    .pill {
      margin-left: auto; display: inline-flex; align-items: center; gap: 6px;
      padding: 4px 10px; background: rgba(34, 197, 94, 0.12);
      color: var(--luna-green); border-radius: 999px;
      font-size: 12px; font-weight: 600;
    }
    .pill .dot {
      width: 6px; height: 6px; border-radius: 50%;
      background: var(--luna-green);
      animation: pulse 2s infinite;
    }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
    .hero {
      padding: 32px 28px; background: var(--card);
      border: 1px solid var(--border); border-radius: 12px; margin-bottom: 20px;
    }
    .hero h1 { font-size: 28px; font-weight: 800; margin-bottom: 8px; }
    .hero h1 .accent { color: var(--luna-green); }
    .hero p { color: var(--sub); font-size: 14px; margin-bottom: 16px; }
    .url-card {
      background: #0b0e14; border: 1px solid var(--border);
      border-radius: 8px; padding: 14px 16px;
      font-family: 'SF Mono', Consolas, Monaco, monospace;
      font-size: 13px; color: var(--luna-green);
      word-break: break-all; margin-bottom: 8px;
    }
    .url-card .label {
      color: var(--muted); font-size: 11px; text-transform: uppercase;
      letter-spacing: 0.05em; margin-bottom: 6px;
      font-family: -apple-system, sans-serif;
    }
    .section {
      background: var(--card); border: 1px solid var(--border);
      border-radius: 12px; padding: 20px 24px; margin-bottom: 16px;
    }
    .section-title {
      display: flex; align-items: center; gap: 10px;
      font-size: 16px; font-weight: 700; margin-bottom: 14px;
    }
    .section-title::before {
      content: ""; width: 3px; height: 14px;
      background: linear-gradient(180deg, var(--luna-green), var(--luna-green-deep));
      border-radius: 2px;
    }
    .section p { color: var(--sub); font-size: 14px; margin-bottom: 10px; }
    .section p:last-child { margin-bottom: 0; }
    pre {
      background: #0b0e14; color: #d1d5db; padding: 14px 16px;
      border-radius: 8px; border: 1px solid var(--border);
      overflow-x: auto; font-family: 'SF Mono', Consolas, Monaco, monospace;
      font-size: 12.5px; line-height: 1.6; margin: 10px 0; white-space: pre;
    }
    pre .g { color: var(--luna-green); }
    pre .d { color: var(--muted); }
    pre .b { color: #60a5fa; }
    code {
      background: rgba(34, 197, 94, 0.12); color: var(--luna-green);
      padding: 2px 6px; border-radius: 4px;
      font-family: 'SF Mono', Consolas, Monaco, monospace; font-size: 12.5px;
    }
    ul { list-style: none; padding: 0; margin: 8px 0; }
    li {
      color: var(--sub); font-size: 14px; padding: 6px 0;
      display: flex; align-items: center; gap: 8px;
    }
    li::before {
      content: ""; width: 5px; height: 5px;
      background: var(--luna-green); border-radius: 50%; flex-shrink: 0;
    }
    .grid {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 10px; margin-top: 8px;
    }
    .feat {
      background: rgba(255, 255, 255, 0.03); border: 1px solid var(--border);
      border-radius: 8px; padding: 12px 14px; font-size: 13.5px; color: var(--sub);
    }
    .feat b { color: var(--luna-green); font-weight: 600; }
    .footer {
      text-align: center; padding: 20px 0 4px 0;
      color: var(--muted); font-size: 12.5px;
    }
    .footer a { color: var(--luna-green); text-decoration: none; }
    .footer a:hover { text-decoration: underline; }
    .fork-badge {
      display: inline-block; padding: 3px 8px; margin-left: 8px;
      background: rgba(96, 165, 250, 0.12); color: #60a5fa;
      border-radius: 4px; font-size: 11px; font-weight: 600;
      vertical-align: middle;
    }
    @media (max-width: 600px) {
      body { padding: 16px 12px; }
      .hero { padding: 22px 18px; }
      .hero h1 { font-size: 22px; }
      .section { padding: 16px 18px; }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="topbar">
      <div class="logo">TB</div>
      <span class="brand">TMDBG</span>
      <span class="fork-badge">fork of HuntzzZ/tmdb-proxy</span>
      <span class="pill"><span class="dot"></span>运行中</span>
    </div>

    <div class="hero">
      <h1>TMDB + Bangumi 代理 <span class="accent">/ LunaTV 配套</span></h1>
      <p>基于 Cloudflare Workers 的 API 代理服务, 一个 Worker 同时代理 TMDB 和 Bangumi, 解决影视 / 弹幕网刮削工具的跨域访问问题。</p>
      <div class="url-card">
        <div class="label">TMDB 电影详情 · 在 API 路径前添加 worker 域名</div>
        ${currentOrigin}/movie/550
      </div>
      <div class="url-card">
        <div class="label">Bangumi 条目详情</div>
        ${currentOrigin}/bangumi/v0/subjects/1
      </div>
      <div class="url-card">
        <div class="label">Bangumi 封面图 · lain.bgm.tv 任意路径</div>
        ${currentOrigin}/bgm-img/r/400/pic/cover/l/xx/1/1.jpg
      </div>
    </div>

    <div class="section">
      <div class="section-title">端点</div>
      <ul>
        <li><code>GET /movie/550</code> <code>GET /tv/1399</code> <code>GET /search/movie?query=avatar</code> → TMDB API</li>
        <li><code>GET /image/t/p/w500/xxx.jpg</code> → TMDB 图片 (image.tmdb.org)</li>
        <li><code>GET /bangumi/v0/subjects/1</code> → Bangumi API (api.bgm.tv)</li>
        <li><code>GET /bangumi/v0/search/subjects?keyword=CLANNAD</code> → Bangumi 搜索</li>
        <li><code>GET /bgm-img/{lain.bgm.tv 路径}</code> → Bangumi 图片 (lain.bgm.tv)</li>
        <li><code>GET /health</code> 健康检查</li>
        <li><code>GET /</code> 本说明页</li>
      </ul>
    </div>

    <div class="section">
      <div class="section-title">用法示例</div>
      <p>原始 Bangumi API:</p>
      <pre>https://<span class="b">api.bgm.tv</span>/v0/subjects/1</pre>
      <p>通过 Worker 代理 (URL 前面加 <code>${currentOrigin}/bangumi</code>):</p>
      <pre><span class="g">${currentOrigin}/bangumi</span>/v0/subjects/1</pre>
      <p>原始 Bangumi 图片:</p>
      <pre>https://<span class="b">lain.bgm.tv</span>/r/400/pic/cover/l/xx/1/1.jpg</pre>
      <p>通过 Worker 代理:</p>
      <pre><span class="g">${currentOrigin}/bgm-img</span>/r/400/pic/cover/l/xx/1/1.jpg</pre>
    </div>

    <div class="section">
      <div class="section-title">功能特性</div>
      <div class="grid">
        <div class="feat"><b>TMDB 完整 API</b><br>/movie /tv /search /person 等所有端点</div>
        <div class="feat"><b>TMDB 图片</b><br>/image/t/p/{size}/... 全尺寸支持</div>
        <div class="feat"><b>Bangumi v0 API</b><br>透传 Authorization, 可选服务端注入 token</div>
        <div class="feat"><b>Bangumi 图片</b><br>自动补 Referer, 解决 403</div>
        <div class="feat"><b>CORS 全开</b><br>浏览器 / 移动端直接调用</div>
        <div class="feat"><b>UA 强制注入</b><br>满足 api.bgm.tv 的 "App/Version (URL)" 校验</div>
        <div class="feat"><b>图片 1 天缓存</b><br>边缘节点缓存, 减少上游压力</div>
        <div class="feat"><b>API 密钥保护</b><br>TMDB key 服务端注入, 客户端不带</div>
      </div>
    </div>

    <div class="section">
      <div class="section-title">配套 App</div>
      <p>推荐配合 <code>LunaTV-Mobile</code> 使用, 在 App 设置中填入 worker 域名即可:</p>
      <pre>TMDB 数据源  → <span class="g">CF Worker 加速</span> (worker URL)
Bangumi API   → <span class="g">CF Worker 加速</span> (worker URL + /bangumi)
Bangumi 图片  → <span class="g">CF Worker 加速</span> (worker URL + /bgm-img)</pre>
    </div>

    <div class="footer">
      <a href="https://github.com/djsevenx1/tmdb-proxy" target="_blank">djsevenx1/tmdb-proxy</a>
      &nbsp;·&nbsp; <span style="color: var(--muted)">致谢</span> &nbsp;
      <a href="https://github.com/HuntzzZ/tmdb-proxy" target="_blank">HuntzzZ/tmdb-proxy</a>
      &nbsp;·&nbsp;
      <a href="https://github.com/djsevenx1/LunaTV-Mobile" target="_blank">LunaTV-Mobile</a>
    </div>
  </div>
</body>
</html>`

  return new Response(html, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
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
// 用途: 配套 LunaTV-Mobile v2.1.46+ 内建更新器. 走 worker 解决国内 GFW
//   完全拉不到 api.github.com 的问题.
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
// 用途: LunaTV-Mobile v2.1.46+ app 内建下载器拿 APK. 直接下 GitHub
//   release asset 国内 GFW 完全不可达, 走 worker 反代 + 流式转发,
//   跟用户用代理浏览器下一样效果, 但 app 内可以画进度条 / 调起
//   APK 安装器.
//
// 注意: stream body 不能用 withCors 包 (Response 二次构造 body
//   会 buffer 到内存, 几十 MB APK 直接爆). 走原始 response, 用
//   mutable Headers 手动加 CORS.
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

// ===== 短剧 TVBox API 代理 (/sd-api/{src}) =====
//
// 格式: GET /sd-api/{src}?ac=detail&t=64&pg=1
//   src 映射到写死的 3 个 TVBox 源:
//     tyyszy → https://tyyszyapi.com/api.php/provide/vod
//     wujin  → https://api.wujinapi.com/api.php/provide/vod
//     lzi    → https://cj.lziapi.com/api.php/provide/vod
//   query params 透传给上游 (ac / t / pg 等 TVBox 协议标准参数).
//
// 边缘缓存 5 分钟 (TVBox 列表更新不频繁, 5 分钟足够).
// 配套 LunaTV-Mobile v2.5.28+ ShortDramaDirectService 走 worker 代理,
// 一次「全部」tab 27 个请求走 CF 边缘缓存, 命中后毫秒级返回.
const SHORT_DRAMA_SOURCES = {
  tyyszy: 'https://tyyszyapi.com/api.php/provide/vod',
  wujin:  'https://api.wujinapi.com/api.php/provide/vod',
  lzi:    'https://cj.lziapi.com/api.php/provide/vod',
}

async function handleShortDramaApi(request, url, corsHeaders) {
  // /sd-api/{src} → 取 src key
  const srcKey = url.pathname.replace('/sd-api/', '')
  if (!srcKey || !SHORT_DRAMA_SOURCES[srcKey]) {
    return jsonError('Unknown short drama source. Expected /sd-api/{tyyszy|wujin|lzi}', 400, corsHeaders)
  }
  const apiUrl = SHORT_DRAMA_SOURCES[srcKey] + url.search
  let response
  try {
    response = await fetch(apiUrl, {
      method: request.method,
      headers: {
        'User-Agent': 'LunaTV-Mobile-Worker',
        'Accept': 'application/json',
      },
    })
  } catch (e) {
    return jsonError('Short drama API upstream unreachable', 502, corsHeaders,
      { url: apiUrl, message: e.message })
  }
  // 透传上游 JSON, 加 5 分钟边缘缓存
  const newHeaders = new Headers(response.headers)
  for (const [k, v] of Object.entries(corsHeaders)) {
    newHeaders.set(k, v)
  }
  newHeaders.set('Cache-Control', 'public, max-age=300')
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  })
}

// ===== 短剧图片代理 (/sd-img?url={原URL}) =====
//
// 格式: GET /sd-img?url=https://任意图床域名/xxx.jpg
//   短剧封面来自 TVBox 源各自的图床, 域名不固定, 用 query param
//   传完整原 URL. worker 透传 + 1 天边缘缓存.
//
// 安全: 只允许 http/https, 拒绝 file:// / data: / 内网 IP (防 SSRF).
async function handleShortDramaImage(request, url, corsHeaders) {
  const originalUrl = url.searchParams.get('url')
  if (!originalUrl) {
    return jsonError('Missing ?url= parameter', 400, corsHeaders)
  }
  // 基本校验: 只代理 http/https
  if (!originalUrl.startsWith('http://') && !originalUrl.startsWith('https://')) {
    return jsonError('Only http/https URLs are allowed', 400, corsHeaders)
  }

  let response
  try {
    response = await fetch(originalUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      },
    })
  } catch (e) {
    return jsonError('Short drama image upstream unreachable', 502, corsHeaders,
      { url: originalUrl, message: e.message })
  }
  if (!response.ok) {
    return jsonError('Image not found', response.status, corsHeaders, { url: originalUrl })
  }
  const contentType = response.headers.get('content-type') || 'image/jpeg'
  const buf = await response.arrayBuffer()
  return new Response(buf, {
    status: response.status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400', // 缓存 1 天
      ...corsHeaders,
    },
  })
}
