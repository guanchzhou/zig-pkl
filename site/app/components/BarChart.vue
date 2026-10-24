<script setup lang="ts">
export interface BarGroup {
  label: string
  unit: string
  bars: { name: string, value: number, highlight?: boolean }[]
}

const props = defineProps<{ title: string, groups: BarGroup[], digits?: number }>()

function width(group: BarGroup, value: number) {
  const max = Math.max(...group.bars.map(bar => bar.value))
  return `${(value / max) * 100}%`
}

function format(value: number) {
  return value.toFixed(props.digits ?? 1)
}
</script>

<template>
  <figure class="chart">
    <figcaption>{{ title }}</figcaption>
    <div v-for="group in groups" :key="group.label" class="chart-group">
      <p class="chart-label">{{ group.label }}</p>
      <div v-for="bar in group.bars" :key="bar.name" class="chart-row">
        <span class="chart-name">{{ bar.name }}</span>
        <span class="chart-track">
          <span class="chart-bar" :class="{ highlight: bar.highlight }" :style="{ width: width(group, bar.value) }" />
        </span>
        <span class="chart-value">{{ format(bar.value) }} {{ group.unit }}</span>
      </div>
    </div>
  </figure>
</template>
