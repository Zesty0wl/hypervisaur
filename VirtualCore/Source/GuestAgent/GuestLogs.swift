import Foundation

/// The guest's logs, which the agent shows by running a command that prints them.
public enum GuestLogs {
    /// A command that prints recent entries from the guest's logs and then each new entry as it's logged, until it's stopped.
    public static func followCommand(for systemType: VBGuestType) -> String {
        switch systemType {
        case .windows:
            """
            \(windowsFunctions)
            $last = @{}
            $recent = foreach ($log in $logs) {
                $events = @(Get-WinEvent -LogName $log -MaxEvents 50 -ErrorAction SilentlyContinue)
                $last[$log] = if ($events.Count) { ($events | Measure-Object RecordId -Maximum).Maximum } else { 0 }
                $events
            }
            Show-Events ($recent | Sort-Object TimeCreated)
            while ($true) {
                Start-Sleep -Seconds 1
                $new = foreach ($log in $logs) {
                    $events = @(Get-WinEvent -LogName $log -FilterXPath "*[System[EventRecordID>$($last[$log])]]" -ErrorAction SilentlyContinue)
                    if ($events.Count) {
                        $last[$log] = ($events | Measure-Object RecordId -Maximum).Maximum
                        $events
                    }
                }
                if ($new) { Show-Events ($new | Sort-Object TimeCreated) }
            }
            """
        case .mac:
            /// The full path is needed because zsh, the login shell commands run in, has a built-in command called `log`.
            """
            /usr/bin/log show --style compact --last 1m
            exec /usr/bin/log stream --style compact
            """
        case .linux:
            """
            if command -v journalctl >/dev/null 2>&1; then
                exec journalctl --follow --lines=100 --no-pager --output=short-iso
            else
                exec tail -n 100 -F /var/log/syslog /var/log/messages 2>/dev/null
            fi
            """
        }
    }

    /// A command that prints the most recent entries from the guest's logs, oldest first.
    public static func recentCommand(for systemType: VBGuestType, count: Int) -> String {
        switch systemType {
        case .windows:
            """
            \(windowsFunctions)
            $events = foreach ($log in $logs) { Get-WinEvent -LogName $log -MaxEvents \(count) -ErrorAction SilentlyContinue }
            Show-Events ($events | Sort-Object TimeCreated | Select-Object -Last \(count))
            """
        case .mac:
            "/usr/bin/log show --style compact --last 10m | tail -n \(count)"
        case .linux:
            """
            if command -v journalctl >/dev/null 2>&1; then
                journalctl --lines=\(count) --no-pager --output=short-iso
            else
                tail -n \(count) /var/log/syslog /var/log/messages 2>/dev/null
            fi
            """
        }
    }

    /// Windows logs events to its System and Application logs, and they're shown one per line, with the first line of each
    /// event's message. Windows can't follow its logs from the command line, so new events are looked for by their record numbers.
    private static let windowsFunctions = """
    $logs = 'System', 'Application'
    function Show-Events($events) {
        foreach ($entry in $events) {
            $message = "$($entry.Message)".Trim() -split "\\r?\\n" | Select-Object -First 1
            '{0:yyyy-MM-dd HH:mm:ss} {1,-11} {2,-11} {3}: {4}' -f $entry.TimeCreated, $entry.LogName, $entry.LevelDisplayName, $entry.ProviderName, $message
        }
    }
    """
}
