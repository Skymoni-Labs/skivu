package org.skivu.engine.adb

import java.util.UUID

/** Own one POSIX session, not an arbitrary process name or PID supplied by a model. */
class OwnedAdbJob(val port: Int, val legacy: Boolean) {
    val id = UUID.randomUUID().toString().replace("-", "")
    val heartbeat = "SKIVU_LEASE_$id"
    val expiredMarker = "SKIVU_LEASE_EXPIRED_$id"
    private val directory = "/data/local/tmp/.skivu-engine-job-$id"
    private val d = '$'
    val cancellationScheduled = java.util.concurrent.atomic.AtomicBoolean(false)
    private fun quote(text: String) = "'" + text.replace("'", "'\\''") + "'"
    private fun cleanup() = "rm -f -- '$directory/identity' '$directory/identity.tmp' '$directory/lease-expired'; rmdir -- '$directory' 2>/dev/null"

    fun script(command: String): String {
        val delimiter = "SKIVU_SCRIPT_$id"
        require(!command.lineSequence().any { it == delimiter })
        val supervisor = """
            umask 077
            trap 'kill -KILL -- -${d}${d}' HUP TERM
            skivu_job_pid=${d}${d}
            set -- ${d}(cat /proc/${d}skivu_job_pid/stat) || exit 73
            skivu_job_start=${d}{22}
            set --
            printf '%s %s\n' "${d}skivu_job_pid" "${d}skivu_job_start" > '$directory/identity.tmp' || exit 73
            mv -f -- '$directory/identity.tmp' '$directory/identity' || exit 73
            (
              trap 'exit 0' HUP TERM
              while IFS= read -r -t 8 skivu_beat <&3 2>/dev/null; do
                [ "${d}skivu_beat" = '$heartbeat' ] || break
              done
              : > '$directory/lease-expired'
              kill -KILL -- "-${d}skivu_job_pid"
            ) &
            skivu_lease_pid=${d}!
            /system/bin/sh 3<&-
            skivu_job_code=${d}?
            kill -TERM "${d}skivu_lease_pid" 2>/dev/null
            wait "${d}skivu_lease_pid" 2>/dev/null
            exit "${d}skivu_job_code"
        """.trimIndent()
        val onDisconnect = cancellationScript(false) + "\nexit 130"
        val header = """
            umask 077
            mkdir -- '$directory' || exit 73
            trap ${quote(onDisconnect)} HUP TERM
            /system/bin/setsid /system/bin/sh -c ${quote(supervisor)} 3<&0 <<'$delimiter'
        """.trimIndent()
        val footer = """
            skivu_job_code=${d}?
            trap - HUP TERM
            if [ -f '$directory/lease-expired' ]; then
              printf '$expiredMarker\n' >&2
              skivu_job_code=125
            fi
            ${cleanup()}
            exit "${d}skivu_job_code"
        """.trimIndent()
        // Keep the quoted heredoc delimiter at column zero for multiline user code.
        // Parse one complete compound command before dedicating stdin to the lease.
        return "{\n" + header + "\n" + command + "\n" + delimiter + "\n" + footer + "\n}\n"
    }

    fun cancellationScript(clean: Boolean = true): String = """
        skivu_job_attempt=0
        while [ ! -s '$directory/identity' ] && [ "${d}skivu_job_attempt" -lt 20 ]; do
          sleep 0.05
          skivu_job_attempt=${d}((skivu_job_attempt + 1))
        done
        read -r skivu_job_pid skivu_job_start skivu_job_extra < '$directory/identity' || exit 75
        case "${d}skivu_job_pid:${d}skivu_job_start" in *[!0-9:]*|:*|*:) exit 75;; esac
        [ -z "${d}skivu_job_extra" ] && [ "${d}{#skivu_job_pid}" -le 10 ] && [ "${d}skivu_job_pid" -gt 1 ] || exit 75
        skivu_job_has_live() {
          skivu_job_list=${d}(/system/bin/ps -A -o PGID,STAT) || return 2
          set -- ${d}skivu_job_list
          while [ "${d}#" -ge 2 ]; do
            if [ "${d}1" = "${d}skivu_job_pid" ]; then
              case "${d}2" in Z*) ;; *) return 0;; esac
            fi
            shift 2
          done
          return 1
        }
        skivu_job_identity_matches() {
          [ -r "/proc/${d}skivu_job_pid/stat" ] || return 1
          set -- ${d}(cat "/proc/${d}skivu_job_pid/stat") || return 1
          [ "${d}5" = "${d}skivu_job_pid" ] && [ "${d}{22}" = "${d}skivu_job_start" ]
        }
        skivu_job_has_live
        skivu_job_state=${d}?
        [ "${d}skivu_job_state" -ne 2 ] || exit 75
        if [ "${d}skivu_job_state" -eq 0 ]; then
          skivu_job_identity_matches || exit 75
          kill -TERM -- "-${d}skivu_job_pid" 2>/dev/null
          sleep 0.15
          skivu_job_has_live
          skivu_job_state=${d}?
          [ "${d}skivu_job_state" -ne 2 ] || exit 75
          if [ "${d}skivu_job_state" -eq 0 ]; then
            skivu_job_identity_matches || exit 75
            kill -KILL -- "-${d}skivu_job_pid" 2>/dev/null
            sleep 0.1
          fi
        fi
        skivu_job_has_live
        [ "${d}?" -eq 1 ] || exit 75
        ${if (clean) cleanup() else ":"}
        printf 'SKIVU_OWNED_GROUP_STOPPED\n'
    """.trimIndent()
}
