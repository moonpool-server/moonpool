#!/usr/bin/env bats
# The join watcher must capture the EOS connection-type line, which carries the
# authoritative direct-vs-relay proof (NetworkType=[EOS_NCT_DirectConnection]).
# Before, PAT dropped it, so a direct connection could never be proven from the log.

pat() { sed -n "s/^PAT='\(.*\)'\$/\1/p" "$BATS_TEST_DIRNAME/../scripts/join-watch.sh"; }

@test "PAT captures a direct-connection establishment line" {
  line='[2026.11.04-02.12.18:900][98]LogEOSSDK: LogEOSP2P: Connection established. ConnectionType=[EOS_CET_NewConnection] NetworkType=[EOS_NCT_DirectConnection]'
  run grep -qE "$(pat)" <<<"$line"
  [ "$status" -eq 0 ]
}

@test "PAT captures a relayed-connection establishment line" {
  line='[2026.11.03-17.59.55:900][854]LogEOSSDK: LogEOSP2P: Connection established. NetworkType=[EOS_NCT_RelayedConnection]'
  run grep -qE "$(pat)" <<<"$line"
  [ "$status" -eq 0 ]
}

@test "PAT captures the host losing Epic's lobby link, and not a clean close" {
  run grep -qE "$(pat)" <<<'[2026.11.07-04.07.07:747][342]LogEOSSDK: LogEOSLobby: Connection Closed Status: 1006 Message:  Clean: false'
  [ "$status" -eq 0 ]
  run grep -qE "$(pat)" <<<'[2026.11.07-04.07.07:747][342]LogEOSSDK: LogEOSLobby: Connection Closed Status: 1000 Message:  Clean: true'
  [ "$status" -ne 0 ]
}

@test "after a lobby drop the host re-hosts only when empty and not twice in 20 minutes" {
  . "$BATS_TEST_DIRNAME/../scripts/common.sh"
  [ "$(lobby_drop_action 0 '')" = rehost ]
  [ "$(lobby_drop_action 2 '')" = wait ]
  [ "$(lobby_drop_action 0 300)" = wait ]
  [ "$(lobby_drop_action 0 1500)" = rehost ]
  [ "$(LOBBY_DROP_REHOST=false lobby_drop_action 0 '')" = off ]
}

@test "PAT ignores ordinary gameplay noise" {
  line='[2026.11.04-02.12.24:571][683]LogUWEAnalytics: Warning: RecordPlayerEvent item_equipped'
  run grep -qE "$(pat)" <<<"$line"
  [ "$status" -ne 0 ]
}
