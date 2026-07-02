#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises'
import { D2 } from '@terrastruct/d2'

const d2 = new D2()

for (let f of process.argv.slice(2)) {
  let src = await readFile(f, 'utf8')
  let { diagram, renderOptions } = await d2.compile(src, { pad: 0 })
  let svg = await d2.render(diagram, renderOptions)
  let out = f.replace(/\.d2$/, '.svg')
  await writeFile(out, svg)
  console.log(`${f} -> ${out}`)
}

process.exit(0)
