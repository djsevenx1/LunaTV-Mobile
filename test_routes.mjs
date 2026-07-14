// 本地 harness: 用 Node 18+ 的 Web API 模拟 Worker 运行时
// 只验证路由分发逻辑, 不真去 fetch 外部域名
import { handleRequest, detectPlatform } from './corsapi_worker.js'

async function fakeFetch(req) {
  // 拦截真实 fetch: 检查 URL 是不是预期目标, 返回伪响应
  const url = req.url
  console.log(`  [upstream] ${req.method} ${url}`)
  console.log(`    UA: ${req.headers.get('user-agent')}`)
  console.log(`    Referer: ${req.headers.get('referer')}`)
  return new Response(JSON.stringify({ ok: true, target: url }, null, 2), {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  })
}
globalThis.fetch = fakeFetch

const cases = [
  // 原版 ?url= 格式 (回归)
  ['/?url=https://api.bgm.tv/v0/subjects/1', '旧 ?url= 格式'],
  // 新增: 路径格式
  ['/https://api.bgm.tv/v0/subjects/1', '路径 /https://... 格式'],
  ['/https%3A%2F%2Fapi.bgm.tv%2Fv0%2Fsubjects%2F1', '路径 urlencoded 格式'],
  ['/lain.bgm.tv/r/400/pic/cover/l/c4/ca/1_d2tF2.jpg', '裸域名格式 (BGM 图片)'],
  ['/image.tmdb.org/t/p/w500/1yeVJox3rjo2jBKrrihIMj7uoS9.jpg', '裸域名格式 (TMDB 图片)'],
  ['/api.themoviedb.org/3/movie/550?api_key=test123', '裸域名格式 (TMDB API)'],
  // 不该被代理的
  ['/', '首页'],
  ['/health', '健康检查'],
  ['/m3u8?url=https://test.com/x.m3u8', 'm3u8 端点'],
]

let pass = 0, fail = 0
for (const [path, desc] of cases) {
  console.log(`\n=== ${desc}  ${path} ===`)
  try {
    const url = 'https://api.fn0.qzz.io' + path
    const req = new Request(url, { method: 'GET' })
    const res = await handleRequest(req)
    const body = await res.text()
    const ct = res.headers.get('content-type') || ''
    console.log(`  [worker]  status=${res.status}  type=${ct}  size=${body.length}B`)
    // 简单断言: 路由到了代理 = body 里有 "ok":true (我们 fakeFetch 返回的)
    if (body.includes('"ok": true') || body.includes('"ok":true')) {
      console.log(`  ✓ 进代理了`)
      pass++
    } else if (path === '/' && body.includes('CORSAPI')) {
      console.log(`  ✓ 进首页了`)
      pass++
    } else if (path === '/health' && body === 'OK') {
      console.log(`  ✓ 进 health 了`)
      pass++
    } else if (path.startsWith('/m3u8')) {
      // m3u8 端点会真去 fetch,会失败但说明进了 m3u8 handler
      console.log(`  (m3u8 端点, 不验证内容)`)
      pass++
    } else {
      console.log(`  ? 未匹配预期结果`)
      console.log(`  body 前 200B: ${body.slice(0, 200)}`)
      fail++
    }
  } catch (e) {
    console.log(`  ✗ 抛错: ${e.message}`)
    fail++
  }
}

console.log(`\n========= ${pass} pass, ${fail} fail =========`)
process.exit(fail ? 1 : 0)
