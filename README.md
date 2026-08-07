# fiotransfer

Two small Bash commands for transferring files through [file.io](https://file.io):

- `fiotransfer FILE` uploads a file and prints a compact share code.
- `fiotransfer uninstall` removes an installer-managed installation.
- `fioget CODE_OR_URL [OUTPUT_FILE]` downloads it, assembling large uploads automatically.

Instead of copying a complete URL such as `https://file.io/Ab3-xY9`, you can
share only `Ab3-xY9`. The code is the random file.io key with the predictable
URL prefix removed, so it is lossless and requires no additional lookup
service.

## Requirements

- Bash
- curl

## Installation

Clone the repository and run the installer:

```bash
git clone https://github.com/BogdanStamenovic/fiotransfer.git
cd fiotransfer
./install.sh
```

The installer copies `fileio.sh` to
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
######################################################################## 100.0%
Code: Ab3-xY9
Download with: fioget Ab3-xY9
```

An upload progress bar is displayed while the file is being transferred.

Download it using the original filename:

```bash
fioget Ab3-xY9
```

Choose a different output filename:

```bash
fioget Ab3-xY9 received.zip
```

`fioget` also accepts a complete file.io URL:

```bash
fioget https://file.io/Ab3-xY9
```

Run either command without arguments to see its usage summary.

## How it works

`fiotransfer` sends a multipart upload to the file.io API and extracts the
returned key. `fioget` reconstructs the API URL from that key, follows the
download redirect, and uses file.io's suggested filename unless an output
filename is supplied.

The code is not encryption and should be treated like the full link: anyone
who has it can download the file.

## Large files

Files larger than 1.5 GiB are uploaded as a chain of approximately 1.5 GiB
pieces. The first piece is uploaded normally. Every later piece contains the
download code for the preceding piece plus its own data, so the code printed at
the end is the only code that needs to be shared.

For example, a three-piece upload works like this:

```text
piece 1 -> code A
piece 2 (contains A) -> code B
piece 3 (contains B) -> code C   <- share this code
```

`fioget C` downloads the pieces in reverse chain order and writes the original
file back in the correct order. This needs temporary disk space while it is
assembling the download. The default piece size can be changed, for example for
testing or for a lower service limit:

```bash
FIOTRANSFER_CHUNK_SIZE_BYTES=$((500 * 1024 * 1024)) fiotransfer large.iso
```

## file.io limits

Limits and retention are controlled by file.io, not this script. At the time
of writing, files uploaded under the free plan are automatically deleted after
their first download. Consult the [file.io plans](https://www.file.io/plans)
and [API documentation](https://www.file.io/developers) for current details.

Multipart uploads consume one one-time link for every piece during assembly.
Consequently, a failed or interrupted multipart download may make the shared
code unusable and require a fresh upload.

Do not upload confidential material unless file.io's privacy, retention, and
security properties are appropriate for it.

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
