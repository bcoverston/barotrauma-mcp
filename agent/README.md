# Agent driver (M1)

The host-side half of the bridge. Polls `state.json`, writes `command`, reads `ack.json`.
No dependencies — Node ≥ 18, ESM.

## Bridge location

The mod writes its files into an `AgentBridge/` folder in Barotrauma's working directory.
The driver defaults to the macOS Steam path:

```
~/Library/Application Support/Steam/steamapps/common/Barotrauma/Barotrauma.app/Contents/MacOS/AgentBridge
```

Override once M0 confirms the real path in-game:

```sh
export BRIDGE_DIR="/abs/path/to/AgentBridge"
```

## Use

```sh
node src/watch.js                  # watch crew/sub state, prints on change (Ctrl-C to stop)
node src/watch.js ping             # liveness check — expects ack did="pong"
node src/watch.js say "moving up"   # speak as the controlled character
```

`watch` reprints the crew table whenever `state.json` changes. The send forms write a
`command`, then block until `ack.json`'s `seq` advances and print the result.

## Caveat

The mod deduplicates on exact `command` file contents, so issuing the *same* command twice
in a row produces no second ack (the send will time out). Change the argument to re-issue.
A later mod revision can switch dedup to a per-command nonce to remove this wart.
