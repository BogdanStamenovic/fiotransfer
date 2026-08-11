# fiotransfer

Two small Bash commands for transferring files through anonymous temporary
file hosts:

- `fiotransfer FILE` uploads a file and prints a compact share code.
- `fiotransfer update` safely updates an installer-managed copy from GitHub.
- `fiotransfer uninstall` removes an installer-managed installation.
- `fiotransfer status` reports loaded providers, reachability, limits, and
  locally tracked usage.
- `fioget CODE_OR_URL [OUTPUT_FILE]` downloads it, assembling large and
  multi-provider uploads automatically.

The uploader currently supports [file.io](https://www.file.io/developers),
[temp.sh](https://temp.sh/), [Litterbox](https://litterbox.catbox.moe/),
[0x0.st](https://0x0.st/), and [Uguu](https://uguu.se/). It measures their
endpoint latency at the start of an upload, balances that latency against how
many parts each service would need, respects known object and hourly limits,
and automatically retries a part through another provider if an upload fails.
The result is still one compact code, regardless of how many providers or
parts were used.

Normal uploads currently load temp.sh, Litterbox, 0x0.st, and Uguu. file.io
remains supported for existing download codes and explicit opt-in uploads, but
is excluded from the default upload pool because its API can stall after
accepting most of a request:

```bash
FIOTRANSFER_PROVIDERS=fileio,temp,litterbox,0x0,uguu fiotransfer archive.zip
```

## Requirements

- Bash 4 or newer
- curl
- GNU coreutils (`base64`, `dd`, `sha256sum`, `stat`, and `wc`)

## Installation

Clone the repository and run the installer:

```bash
git clone https://github.com/BogdanStamenovic/fiotransfer.git
cd fiotransfer
./install.sh
```

The installer copies `fiotransfer.sh` to
`${XDG_DATA_HOME:-$HOME/.local/share}/fiotransfer/`, adds a marked source block
to `~/.bashrc`, and can safely be run again to update an existing installation.
Open a new terminal or reload the current shell:

```bash
source ~/.bashrc
```

## Usage

Upload a file:

```console
$ fiotransfer archive.zip
Uploading archive.zip (24 MiB) with automatic provider fallback.
Uploading part 1 through fileio (24 MiB).
######################################################################## 100.0%
Part 1 uploaded through fileio.
Upload complete (1 part(s)).
Code: Ab3-xY9
Download with: fioget Ab3-xY9
```

An upload progress bar is displayed while the file is being transferred. For
large files, `fiotransfer` also identifies each preparation and upload phase,
shows a progress bar while copying each temporary part, and makes clear that
the network progress applies to the current part.

Download it using the original filename:

```bash
fioget Ab3-xY9
```

Choose a different output filename:

```bash
fioget Ab3-xY9 received.zip
```

New uploads include compact metadata containing the original filename, size,
and SHA-256 digest. `fioget` restores the correct name even when a provider
renames the object, and validates the complete download before placing it at
its destination. An explicitly supplied `OUTPUT_FILE` still takes precedence.

`fioget` also accepts complete HTTPS URLs from supported providers:

```bash
fioget https://file.io/Ab3-xY9
```

Run either command without arguments to see its usage summary.

Inspect the configured providers without uploading anything:

```bash
fiotransfer providers       # providers loaded from FIOTRANSFER_PROVIDERS
fiotransfer limits          # per-object and published hourly limits
fiotransfer usage           # locally observed rolling-hour usage
fiotransfer unresponsive    # providers that fail a live endpoint probe
fiotransfer status          # combined live overview
```

`fiotransfer status` starts with the running copy's revision and commit
subject, followed by the live provider overview. Installer-managed copies read
this version information from local update metadata, so it remains available
without another GitHub request.

The longer aliases `loaded-providers`, `usage-limits`, and
`unresponsive-providers` are also accepted. Live checks use the same endpoint
probe and timeouts as upload routing; they do not upload data.

## How it works

`fiotransfer` sends multipart-form uploads to the providers' public anonymous
APIs. A short prefix identifies non-file.io codes: `t:` for temp.sh, `l:` for
Litterbox, `z:` for 0x0.st, and `u:` for Uguu. Existing bare file.io keys
remain valid. `fioget` resolves the code, follows redirects, and uses embedded
metadata (or, for older uploads, the service's suggested filename) unless an
output filename is supplied.
For temp.sh links it uses the service's POST-based raw-download endpoint
instead of saving the HTML preview returned by a normal GET request.

The code is not encryption and should be treated like the full link: anyone
who has it can download the file.

## Routing, limits, and large files

Each provider declares a maximum object size. file.io also publishes a 4 GB
rolling-hour upload limit, so fiotransfer records its own successful file.io
uploads under `${XDG_STATE_HOME:-$HOME/.local/state}/fiotransfer/usage`. The
record is a best-effort local view: uploads made by another program or device
are discovered when file.io rejects a part, at which point the transfer falls
back automatically.

The defaults reflect the providers' published limits as of August 2026:

| Provider | Per-object limit used | Hourly limit used | Retention behavior |
| --- | ---: | ---: | --- |
| file.io | 2 GB | 4 GB | Deleted after first download on the free plan |
| temp.sh | 4 GB | Not published | Three days |
| Litterbox | 1 GB | Not published | 72 hours |
| 0x0.st | 512 MiB | Not published | Size-dependent, at least 30 days |
| Uguu | 128 MiB | Not published | Three hours |

These are independent services with different privacy and acceptable-use
policies. Codes are access credentials, not encryption. Do not upload content
unless every enabled provider's terms, privacy, retention, and security
properties are appropriate for it.

When the file does not fit one object or a faster provider exhausts its known
allowance, fiotransfer uploads a reverse chain. The first piece is raw data.
Every later piece contains the provider-aware code for the preceding piece plus
its own data, so only the final code needs to be shared. For example, a
three-piece upload works like this:

```text
piece 1 on file.io -> code A
piece 2 on file.io (contains A) -> code B
piece 3 on temp.sh (contains B) -> code C   <- share this code
```

`fioget C` follows the provider locators in reverse order and writes the
original bytes back in the correct order. This needs temporary disk space while
assembling the download.

Provider order can be restricted or changed. Order breaks equal routing-score
ties; measured latency and required part count otherwise decide which eligible
provider is tried first:

```bash
FIOTRANSFER_PROVIDERS=temp,fileio,litterbox fiotransfer large.iso
```

The maximum part size can be lowered for testing or constrained temporary
storage. It never raises a provider's own limit:

```bash
FIOTRANSFER_CHUNK_SIZE_BYTES=$((500 * 1024 * 1024)) fiotransfer large.iso
```

For an isolated test that must not affect normal quota history, set
`FIOTRANSFER_STATE_HOME` to another directory.

Uploads that stop transferring data for 15 seconds are aborted so routing can
fall back instead of waiting indefinitely on a stalled provider. Override the
interval with a positive number of seconds when needed:

```bash
FIOTRANSFER_STALL_TIMEOUT_SECONDS=30 fiotransfer large.iso
```

## One-time-link warning

Every file.io part is a one-time link. A multipart download consumes those
links as it walks the chain. Consequently, a failed or interrupted download
may make the final code unusable and require a fresh upload. The other
providers have different retention rules, but they do not make a mixed chain
recoverable after a required file.io part has been consumed.

## Updating

An installation made by `install.sh` can update itself from this repository's
`main` branch:

```bash
fiotransfer update
```

The updater adapts the staged-validation model from
[auto-update-changer](https://github.com/BogdanStamenovic/auto-update-changer)
to this user-scoped Bash installation. It downloads the replacement beside the
installed file at a commit-pinned URL, verifies that GitHub's current revision
is a fast-forward from the installed revision, checks Bash syntax and required
entry points, detects an already-current copy, creates a timestamped backup,
atomically replaces the installed script, and reloads it into the current
shell. While it runs, it reports the installed and available revisions and
commit subject along with each verification, download, backup, installation,
and reload stage. It refuses rewritten/divergent update history and refuses to
modify a copy sourced directly from a clone or any location not managed by the
installer.

Backups are stored in:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/fiotransfer/backups/
```

Updates trust the code published to the repository's `main` branch. Review the
repository history before updating if that trust model is not suitable.

## Testing

The test suite uses a local mock of all five HTTP APIs and does not create
public uploads:

```bash
tests/run.sh
```

## Uninstall

Run the built-in uninstaller:

```bash
fiotransfer uninstall
```

It displays the affected paths and requires confirmation. It removes only the
installed script and the block managed in `~/.bashrc`; it does not delete the
cloned repository.

## License

[MIT](LICENSE)
