# Independent Umbriel Sink login session

These files support an opt-in session named **Umbriel Sink**. They do not replace
the official compositor, launcher, user service, or display-manager entry.

| Source file | Purpose |
| --- | --- |
| `start-umbriel-sink` | Starts the fork binary from the user's private install directory; refuses to start inside another desktop session. |
| `umbriel-sink.service` | Runs the private binary with the fork-only config overlay. |
| `config.toml` | Example overlay that includes the user's existing Umbriel config. Add Sink/Pull bindings here, not in a file also loaded by the official binary. |
| `umbriel-sink.desktop.in` | Display-manager entry template with an unset launcher path. |
| `install-session-entry.sh` | Inserts the current user's launcher path into the template and installs only the separate `umbriel-sink.desktop` entry via `sudo`. |

See the repository [README](../../README.md) for build and install commands. The default locations are
`~/.local/libexec/umbriel-sink/umbriel-sink` for the release binary,
`~/.local/bin/start-umbriel-sink` for the launcher,
`~/.config/systemd/user/umbriel-sink.service` for the user service, and
`~/.config/umbriel-sink/config.toml` for the fork overlay.

The repository desktop-entry template contains no account-specific path. The
installer generates that path at install time, because display managers need
an executable launcher path in the installed entry. Review the installer
or use `install-session-entry.sh --render` before running it; installation
requests administrator privileges only for the new
system session entry. Copying the built binary is explicit, so rebuilding the
repository does not silently change a running login session. Log out of
Umbriel Sink before replacing its installed binary.
