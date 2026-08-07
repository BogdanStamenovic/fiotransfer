# fiotransfer

Two small Bash commands for transferring files through [file.io](https://file.io):

- `fiotransfer FILE` uploads a file and prints a compact share code.
- `fioget CODE_OR_URL [OUTPUT_FILE]` downloads it.

Instead of copying a complete URL such as `https://file.io/Ab3-xY9`, you can
share only `Ab3-xY9`. The code is the random file.io key with the predictable
URL prefix removed, so it is lossless and requires no additional lookup
service.

## Requirements

- Bash
- curl

## Installation

Clone the repository:

```bash
git clone https://github.com/BogdanStamenovic/fiotransfer.git \
    ~/.local/share/fiotransfer
```

Add this line to `~/.bashrc`:

```bash
source "$HOME/.local/share/fiotransfer/fileio.sh"
```

Reload the shell:

```bash
source ~/.bashrc
```

## Usage

Upload a file:

```console
$ fiotransfer archive.zip
Code: Ab3-xY9
Download with: fioget Ab3-xY9
```

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

## file.io limits

Limits and retention are controlled by file.io, not this script. At the time
of writing, files uploaded under the free plan are automatically deleted after
their first download. Consult the [file.io plans](https://www.file.io/plans)
and [API documentation](https://www.file.io/developers) for current details.

Do not upload confidential material unless file.io's privacy, retention, and
security properties are appropriate for it.

## Uninstall

Remove the `source` line from `~/.bashrc`, then delete the cloned directory:

```bash
rm -r "$HOME/.local/share/fiotransfer"
```

## License

[MIT](LICENSE)
