#!/usr/bin/env node
// A stand-in for an ACP harness installed with npm, for Windows/scripts/check-harness.ps1. It answers
// --version; under `acp` it starts a detached process of its own, which would outlive it, writes both
// process IDs beside itself and answers ACP initialize. It keeps running once its input ends, so it ends
// only when whoever started it ends it.
'use strict'
const { spawn } = require('child_process')
const fs = require('fs')
const path = require('path')

const args = process.argv.slice(2)
fs.appendFileSync(path.join(__dirname, 'calls.log'), JSON.stringify(args) + '\n')
if (args[0] === '--version') {
  console.log('kimi 1.0.0 (Yardlet stand-in)')
  process.exit(0)
}
if (args[0] !== 'acp') {
  console.error('unknown command: ' + JSON.stringify(args))
  process.exit(2)
}

// Detached, libuv leaves it out of node's own job object, so ending this process alone leaves it running.
const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 300000)'],
  { detached: true, stdio: 'ignore', windowsHide: true })
child.unref()
fs.writeFileSync(path.join(__dirname, 'grandchild.pid'), String(child.pid))
fs.writeFileSync(path.join(__dirname, 'cli.pid'), String(process.pid))

let buffer = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', (chunk) => {
  buffer += chunk
  let newline
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline).trim()
    buffer = buffer.slice(newline + 1)
    let message
    try { message = JSON.parse(line) } catch { continue }
    if (message.method === 'initialize') {
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0',
        id: message.id,
        result: { protocolVersion: 1, agentCapabilities: {}, authMethods: [] }
      }) + '\n')
    }
  }
})
setInterval(() => {}, 60000)
