<script setup lang="ts">
const { data: page } = await useRepoDoc('/benchmarks/comparison')
if (!page.value) {
  throw createError({ statusCode: 404, statusMessage: 'Page not found', fatal: true })
}
const summary = benchmarkSummary

const codecCases = [
  ['decode_config', 'Dynamic tree, configuration fixture'],
  ['decode_mixed', 'Dynamic tree, mixed value kinds'],
  ['typed_config', 'Zig structs, configuration fixture'],
] as const

const codec = codecCases.map(([key, label]) => ({
  label,
  unit: 'MiB/s',
  bars: [
    { name: 'pkl-zig', value: summary.codec[key].pkl_zig_mib_s },
    { name: 'zig-pkl', value: summary.codec[key].zig_pkl_mib_s, highlight: true },
  ],
}))

const server = [
  {
    label: 'Start the server, create an evaluator, evaluate, shut down',
    unit: 'ms',
    bars: [
      { name: 'pkl-zig', value: summary.server.pkl_zig_cold_ms },
      { name: 'zig-pkl', value: summary.server.zig_pkl_cold_ms, highlight: true },
    ],
  },
  {
    label: 'Evaluate on a running evaluator',
    unit: 'µs',
    bars: [
      { name: 'pkl-zig', value: summary.server.pkl_zig_warm_us },
      { name: 'zig-pkl', value: summary.server.zig_pkl_warm_us, highlight: true },
    ],
  },
]
</script>

<template>
  <div class="doc-layout">
    <DocNav />
    <article class="prose">
      <div class="charts">
        <BarChart
          :title="`How fast does each library decode pkl-binary? Apple M5, median of ${summary.rounds.zig_pkl} rounds, longer is faster`"
          :groups="codec"
        />
        <BarChart
          title="How long does a request take? Apple M5, Pkl 0.32.2, shorter is faster"
          :groups="server"
          :digits="2"
        />
      </div>
      <ContentRenderer v-if="page" :value="page.doc" />
    </article>
  </div>
</template>
