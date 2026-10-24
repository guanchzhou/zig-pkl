export const repoUrl = 'https://github.com/guanchzhou/zig-pkl'

export const docCollections = [
  { name: 'guides', dir: 'docs/guides' },
  { name: 'reference', dir: 'docs' },
  { name: 'benchmarks', dir: 'docs/benchmarks' },
  { name: 'changelog', dir: '' },
] as const

export type DocCollection = (typeof docCollections)[number]['name']

export const guideOrder = [
  'installation',
  'quickstart',
  'evaluation',
  'projects',
  'security',
  'readers',
  'external-readers',
  'logging',
  'concurrency',
  'errors',
  'ownership',
  'compatibility',
  'migration',
]

export const exampleOrder = [
  'typed',
  'dynamic',
  'expressions',
  'output',
  'project',
  'readers',
  'restricted',
  'external-reader',
  'concurrency',
  'errors',
  'codegen',
]

const routes: Record<string, string> = {
  'docs/codegen.md': '/codegen',
  'docs/benchmarks/comparison.md': '/benchmarks',
  'docs/benchmarks/baseline.md': '/benchmarks/baseline',
  'CHANGELOG.md': '/changelog',
}

function normalize(path: string): string {
  const out: string[] = []
  for (const segment of path.split('/')) {
    if (segment === '' || segment === '.') continue
    if (segment === '..') out.pop()
    else out.push(segment)
  }
  return out.join('/')
}

function knownMarkdown(path: string) {
  return /^docs\/guides\/[\w-]+\.md$/.test(path) || path in routes
}

/** Maps a link in a repository Markdown file to a site route or a GitHub URL. */
export function resolveRepoLink(href: string, source: string): { to: string, internal: boolean } {
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#') || href.startsWith('//')) {
    return { to: href, internal: false }
  }
  const hashIndex = href.indexOf('#')
  const fragment = hashIndex >= 0 ? href.slice(hashIndex) : ''
  const target = hashIndex >= 0 ? href.slice(0, hashIndex) : href
  const base = source.includes('/') ? source.slice(0, source.lastIndexOf('/')) : ''
  const resolved = normalize(target.startsWith('/') ? target : `${base}/${target}`)
  // Nuxt Content drops the extension from relative Markdown links.
  const path = /\.[a-z]+$/i.test(resolved) || !knownMarkdown(`${resolved}.md`) ? resolved : `${resolved}.md`

  const guide = /^docs\/guides\/([\w-]+)\.md$/.exec(path)
  if (guide) return { to: `/guides/${guide[1]}${fragment}`, internal: true }
  if (routes[path]) return { to: `${routes[path]}${fragment}`, internal: true }
  if (path === 'examples') return { to: `/examples${fragment}`, internal: true }
  const example = /^examples\/([\w-]+)(\/main\.zig)?$/.exec(path)
  if (example && exampleOrder.includes(example[1]!)) {
    return { to: `/examples#${example[1]}`, internal: true }
  }
  return { to: `${repoUrl}/blob/main/${path}${fragment}`, internal: false }
}
