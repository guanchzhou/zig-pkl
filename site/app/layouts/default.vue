<template>
  <div class="shell">
    <a class="skip" href="#main">Skip to content</a>
    <header class="topbar">
      <NuxtLink to="/" class="brand">zig-pkl</NuxtLink>
      <nav aria-label="Site">
        <NuxtLink to="/guides/quickstart">Guides</NuxtLink>
        <NuxtLink to="/examples">Examples</NuxtLink>
        <NuxtLink to="/codegen">Codegen</NuxtLink>
        <NuxtLink to="/benchmarks">Benchmarks</NuxtLink>
        <ApiLink>API</ApiLink>
        <a :href="repoUrl">GitHub</a>
      </nav>
    </header>
    <main id="main">
      <slot />
    </main>
    <footer class="footer">
      <p>
        zig-pkl is licensed under Apache-2.0.
        <a :href="repoUrl">Source</a> ·
        <a :href="`${repoUrl}/releases`">Releases</a> ·
        <NuxtLink to="/changelog">Changelog</NuxtLink> ·
        <a href="https://pkl-lang.org/">Pkl</a>
      </p>
    </footer>
  </div>
</template>
