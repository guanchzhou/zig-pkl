<script setup lang="ts">
const { data: guides } = await useAsyncData('nav:guides', () =>
  queryCollection('guides').select('title', 'path', 'stem').all(),
)

const ordered = computed(() => {
  const rank = (stem: string) => {
    const index = guideOrder.indexOf(stem.split('/').pop() ?? stem)
    return index < 0 ? guideOrder.length : index
  }
  return [...(guides.value ?? [])].sort((a, b) => rank(a.stem) - rank(b.stem))
})
</script>

<template>
  <nav class="doc-nav" aria-label="Documentation">
    <p class="doc-nav-heading">Guides</p>
    <ul>
      <li v-for="guide in ordered" :key="guide.path">
        <NuxtLink :to="guide.path">{{ guide.title }}</NuxtLink>
      </li>
    </ul>
    <p class="doc-nav-heading">Reference</p>
    <ul>
      <li><NuxtLink to="/codegen">Code generation</NuxtLink></li>
      <li><NuxtLink to="/examples">Examples</NuxtLink></li>
      <li><ApiLink>API reference</ApiLink></li>
      <li><NuxtLink to="/benchmarks">Benchmarks</NuxtLink></li>
      <li><NuxtLink to="/changelog">Changelog</NuxtLink></li>
    </ul>
  </nav>
</template>
