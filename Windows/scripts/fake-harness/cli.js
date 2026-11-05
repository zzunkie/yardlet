#!/usr/bin/env node
// A stand-in for an ACP harness installed with npm, for Windows/scripts/check-harness.ps1 and
// check-local.ps1. It answers --version; under `acp` it starts a detached process of its own, which would
// outlive it, writes both process IDs beside itself and serves ACP: initialize, a new session, and a prompt
// that reads a file, asks to edit it, and streams its answer once allowed (or a short one once denied). It
// keeps running once its input ends, so it ends only when whoever started it ends it.
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
    handle(message)
  }
})
setInterval(() => {}, 60000)

const send = (message) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
const update = (sessionId, value) => send({ method: 'session/update', params: { sessionId, update: value } })
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
// What the stand-in asked and is waiting for, by its request ID.
const waiting = new Map()
let nextRequest = 1
let sessions = 0

function ask(method, params) {
  const id = 'stand-in-' + nextRequest++
  send({ id, method, params })
  return new Promise((resolve) => waiting.set(id, resolve))
}

function handle(message) {
  if (message.id !== undefined && message.method === undefined) {
    const resolve = waiting.get(message.id)
    waiting.delete(message.id)
    if (resolve) resolve(message.result)
    return
  }
  switch (message.method) {
    case 'initialize':
      send({ id: message.id, result: { protocolVersion: 1, agentCapabilities: {}, authMethods: [] } })
      break
    case 'session/new':
      sessions += 1
      send({ id: message.id, result: { sessionId: 'stand-in-session-' + sessions } })
      break
    case 'session/prompt':
      prompt(message)
      break
    case 'session/cancel':
      break
    default:
      if (message.id !== undefined) send({ id: message.id, error: { code: -32601, message: 'not served by the stand-in' } })
  }
}

async function prompt(message) {
  const sessionId = message.params.sessionId
  const text = (message.params.prompt || []).map((part) => part.text || '').join(' ')
  update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'read-1', title: 'Read README.md', kind: 'read', status: 'completed' })
  await sleep(300)
  const answer = await ask('session/request_permission', {
    sessionId,
    toolCall: { toolCallId: 'edit-1', title: 'Edit README.md', kind: 'edit', status: 'pending' },
    options: [
      { optionId: 'allow', name: 'Allow', kind: 'allow_once' },
      { optionId: 'reject', name: 'Deny', kind: 'reject_once' }
    ]
  })
  const allowed = answer && answer.outcome && answer.outcome.optionId === 'allow'
  const words = allowed
    ? ('Done. I updated **README.md** for “' + text.slice(0, 80) + '”:\n\n- Added the `install` steps.\n- Checked the links.').split(' ')
    : ['Okay,', 'I', 'left', 'README.md', 'as', 'it', 'was.']
  for (let index = 0; index < words.length; index += 1) {
    update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: (index ? ' ' : '') + words[index] } })
    await sleep(120)
  }
  send({ id: message.id, result: { stopReason: 'end_turn' } })
}
