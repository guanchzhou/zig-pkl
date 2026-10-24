import ciWorkflow from '../../../.github/workflows/ci.yml?raw'
import quickstart from '../../../docs/guides/quickstart.md?raw'
import macosSummary from '../../../docs/benchmarks/results/macos-arm64/summary.json'

const exampleSources = import.meta.glob(
  [
    '../../../examples/*/main.zig',
    '../../../examples/*/*.pkl',
    '../../../examples/*/PklProject',
    '../../../examples/codegen/src/main.zig',
    '../../../examples/codegen/pkl/*.pkl',
  ],
  { query: '?raw', import: 'default', eager: true },
) as Record<string, string>

export interface ExampleFile {
  path: string
  lang: string
  code: string
}

export interface Example {
  name: string
  summary: string[]
  files: ExampleFile[]
}

function summaryOf(code: string): string[] {
  const paragraphs: string[] = []
  let current: string[] = []
  for (const line of code.split('\n')) {
    if (!line.startsWith('//!')) break
    const text = line.slice(3).trim()
    if (text === '') {
      if (current.length) paragraphs.push(current.join(' '))
      current = []
    } else {
      current.push(text)
    }
  }
  if (current.length) paragraphs.push(current.join(' '))
  return paragraphs
}

function isMain(path: string) {
  return path === 'main.zig' || path === 'src/main.zig'
}

export function examples(): Example[] {
  const byName = new Map<string, ExampleFile[]>()
  for (const [key, code] of Object.entries(exampleSources)) {
    const relative = key.slice(key.indexOf('examples/') + 'examples/'.length)
    const name = relative.slice(0, relative.indexOf('/'))
    const path = relative.slice(name.length + 1)
    const lang = path.endsWith('.zig') ? 'zig' : 'pkl'
    byName.set(name, [...(byName.get(name) ?? []), { path, lang, code }])
  }
  const rank = (name: string) => {
    const index = exampleOrder.indexOf(name)
    return index < 0 ? exampleOrder.length : index
  }
  return [...byName.entries()]
    .sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b))
    .map(([name, files]) => {
      files.sort((a, b) => Number(isMain(b.path)) - Number(isMain(a.path)) || a.path.localeCompare(b.path))
      return { name, summary: summaryOf(files[0]?.code ?? ''), files }
    })
}

/** Pkl releases the version matrix job tests, in workflow order. */
export function testedPklVersions(): string[] {
  return [...ciWorkflow.matchAll(/^\s+- pkl: "([\d.]+)"$/gm)].map(match => match[1]!)
}

/** Platforms of the main test job, which runs the newest Pkl release. */
export function testedPlatforms(): { pkl: string, platforms: string[] } {
  const pkl = /PKL_VERSION: "([\d.]+)"/.exec(ciWorkflow)?.[1] ?? ''
  const platforms = [...ciWorkflow.matchAll(/^\s+name: ([a-z0-9]+-[a-z0-9_]+)$/gm)].map(match => match[1]!)
  return { pkl, platforms }
}

/** The first Zig code block of the quick start guide. */
export function quickstartCode(): string {
  return /```zig\n([\s\S]*?)```/.exec(quickstart)?.[1] ?? ''
}

export const benchmarkSummary = macosSummary
