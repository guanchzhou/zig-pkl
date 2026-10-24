<script setup lang="ts">
const list = examples()
const { data: highlighted } = await useHighlighted('examples', list.flatMap(example => example.files))
const offsets = list.map((_, index) => list.slice(0, index).reduce((total, example) => total + example.files.length, 0))
useSeoMeta({
  title: 'Examples | zig-pkl',
  description: 'Runnable zig-pkl programs from the repository',
})
</script>

<template>
  <div class="doc-layout">
    <DocNav />
    <article class="prose">
      <h1>Examples</h1>
      <p>
        Each program lives in <a :href="`${repoUrl}/tree/main/examples`"><code>examples/</code></a>.
        <code>zig build examples</code> runs them all and <code>zig build example-&lt;name&gt;</code> runs one.
        They start the server with <code>PKL_EXEC</code>, or <code>pkl</code> from <code>PATH</code>.
        The <code>codegen</code> example is a separate package; see <NuxtLink to="/codegen">Code generation</NuxtLink>.
      </p>
      <nav class="example-index" aria-label="Examples">
        <a v-for="example in list" :key="example.name" :href="`#${example.name}`">{{ example.name }}</a>
      </nav>
      <section v-for="(example, exampleIndex) in list" :id="example.name" :key="example.name" class="example">
        <h2>
          <a :href="`${repoUrl}/tree/main/examples/${example.name}`">{{ example.name }}</a>
        </h2>
        <p v-for="(paragraph, index) in example.summary" :key="index">{{ paragraph }}</p>
        <details v-for="(file, index) in example.files" :key="file.path" :open="index === 0">
          <summary><code>{{ file.path }}</code></summary>
          <CodeBlock :html="highlighted?.[offsets[exampleIndex]! + index] ?? ''" />
        </details>
      </section>
    </article>
  </div>
</template>
