<script setup lang="ts">
const { data: highlighted } = await useHighlighted('quickstart', [{ code: quickstartCode(), lang: 'zig' }])
const versions = testedPklVersions()
const matrix = testedPlatforms()
const summary = benchmarkSummary

const fewerAllocations = (key: keyof typeof summary.codec) =>
  Math.round(summary.codec[key].pkl_zig_allocations / summary.codec[key].zig_pkl_allocations)

useSeoMeta({
  title: 'zig-pkl: Pkl for Zig 0.17',
  description: 'Zig 0.17 bindings for Pkl: typed evaluation, code generation, readers, and projects.',
})
</script>

<template>
  <div class="home">
    <section class="intro">
      <div class="intro-text">
        <h1>zig-pkl</h1>
        <p class="lede">
          Zig 0.17 bindings for <a href="https://pkl-lang.org/">Pkl</a>. Evaluate modules into Zig
          types, generate those types from Pkl schemas, and serve modules and resources from your
          own code.
        </p>
        <pre class="install"><code>zig fetch --save git+https://github.com/guanchzhou/zig-pkl</code></pre>
        <p class="actions">
          <NuxtLink to="/guides/quickstart" class="primary">Quick start</NuxtLink>
          <NuxtLink to="/guides/installation">Installation</NuxtLink>
          <ApiLink>API reference</ApiLink>
        </p>
      </div>
      <div class="intro-code">
        <p class="caption">Read <code>config.pkl</code> into a struct</p>
        <CodeBlock :html="highlighted?.[0] ?? ''" />
      </div>
    </section>

    <section class="features">
      <h2>What the package covers</h2>
      <dl>
        <div>
          <dt><NuxtLink to="/guides/evaluation">Typed and dynamic evaluation</NuxtLink></dt>
          <dd>Decode a module or an expression into Zig structs, unions, enums, slices, and maps, or walk the value tree.</dd>
        </div>
        <div>
          <dt><NuxtLink to="/codegen">Code generation</NuxtLink></dt>
          <dd><code>zig-pkl-gen</code> writes Zig types from Pkl modules, including recursive classes and unions of unrelated types.</dd>
        </div>
        <div>
          <dt><NuxtLink to="/guides/readers">Readers</NuxtLink></dt>
          <dd>Serve modules and resources from Zig callbacks, or run your program as an external reader that Pkl starts.</dd>
        </div>
        <div>
          <dt><NuxtLink to="/guides/projects">Projects</NuxtLink></dt>
          <dd>Load <code>PklProject</code> settings and dependencies, with the same path rules on every supported Pkl release.</dd>
        </div>
        <div>
          <dt><NuxtLink to="/guides/concurrency">Concurrency</NuxtLink></dt>
          <dd>One server process shared by evaluators on any thread, with per-call timeouts and cancellation.</dd>
        </div>
        <div>
          <dt><NuxtLink to="/guides/security">Restricted evaluation</NuxtLink></dt>
          <dd>Allow lists for modules and resources, an empty environment by default, and HTTP settings.</dd>
        </div>
      </dl>
    </section>

    <section class="numbers">
      <h2>Measured against pkl-zig</h2>
      <p>
        Same run, same Pkl 0.32.2 executable, Apple M5, median of {{ summary.rounds.zig_pkl }} rounds.
        <NuxtLink to="/benchmarks">Method, Linux results, and raw data</NuxtLink>.
      </p>
      <ul>
        <li>
          <strong>{{ summary.gates.codec_geometric_mean_speedup.toFixed(2) }}×</strong>
          <span>faster pkl-binary decoding, geometric mean of three cases</span>
        </li>
        <li>
          <strong>{{ fewerAllocations('decode_config') }}×</strong>
          <span>fewer allocations decoding a configuration into a value tree</span>
        </li>
        <li>
          <strong>{{ summary.server.zig_pkl_cold_ms.toFixed(2) }} ms</strong>
          <span>to start the server, evaluate, and shut down; pkl-zig {{ summary.server.pkl_zig_cold_ms.toFixed(2) }} ms</span>
        </li>
        <li>
          <strong>{{ summary.server.zig_pkl_warm_us.toFixed(1) }} µs</strong>
          <span>per evaluation on a running evaluator; pkl-zig {{ summary.server.pkl_zig_warm_us.toFixed(1) }} µs</span>
        </li>
      </ul>
    </section>

    <section class="versions">
      <h2>Tested Pkl releases</h2>
      <p>
        CI runs the conformance suite, the integration tests, and every example against each of these
        releases on Linux, and Pkl {{ matrix.pkl }} on {{ matrix.platforms.join(', ') }}.
      </p>
      <ul class="version-list">
        <li v-for="version in versions" :key="version">{{ version }}</li>
      </ul>
      <p>
        Some settings need a newer release. See
        <NuxtLink to="/guides/compatibility">version compatibility</NuxtLink>, or
        <NuxtLink to="/guides/migration">migrating from pkl-zig</NuxtLink>.
      </p>
    </section>
  </div>
</template>
