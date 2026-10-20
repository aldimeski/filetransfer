# PerlFileTransfer (`file_tran.pl`)

Generic file-management tool (copy / move / archive, with health checks and
optional SFTP) used in the revenue-assurance data workflow. It transfers files
from source directories (where external parties deliver them) to the target
directories of the consuming application, optionally applying completeness checks
and file operations (zip/unzip/archive/decode) during the transfer.

Originally developed for a revenue-assurance data workflow.

## Requirements

- Perl 5
- Perl modules:
  - `Data::Dumper`
  - `DirHandle`
  - `File::Basename`
  - `File::Copy`
  - `File::Find::Rule`
  - `Array::Utils`
  - `MIME::Lite`
  - `Net::SFTP::Foreign`
  - `Date::Parse`
  - `DateTime`

Install the dependencies with cpan, e.g.:

```sh
sudo cpan install Data::Dumper DirHandle File::Basename File::Copy \
  File::Find::Rule Array::Utils MIME::Lite Net::SFTP::Foreign Date::Parse DateTime
```

For the RHEL9 / self-compiled Perl 5.40 procedure (proxy, PERL5LIB, crontab
variables) see the operations document
`documents/RACO-PerlFileTransfer-191026-1247-6176.pdf`.

## Installation

```sh
mkdir -p /opt/filetransfer/ && cd /opt/filetransfer/
git clone <repo-url> bin
sudo chmod +x /opt/filetransfer/bin/file_tran.pl
mkdir -p /opt/filetransfer/param /opt/filetransfer/pass
```

Resulting layout:

```
/opt/filetransfer/
  bin/   file_tran.pl, README.md, ParamTest1.param
  param/ <job>.param files
  pass/  <job>.pass files (SFTP Clear mode)
```

Smoke test (should complain that no param file was given):

```sh
bin/file_tran.pl
# No parameter file is provided, can't do jack!
```

## Usage

```sh
file_tran.pl /path/to/job.param
```

The single argument is a `.param` file that fully configures one transfer job.

## Parameter file

| Parameter | Value | Description |
|---|---|---|
| `InputDir` | dir path | Source directory |
| `OutputDir` | dir path(s) | Target directory. Comma-separated list = multiple targets |
| `KeepInput` | `Y`/`N` | `Y` copy (leave source intact), `N` move |
| `SftpCheck` | `Y`/`N` | `Y` SFTP mode, `N` local mode |
| `SftpType` | `Clear`/`Key` | SFTP auth method |
| `SftpPassFile` | file path | File containing the password (SftpType `Clear`) |
| `SftpHost` | host/IP | Remote host |
| `SftpUser` | user | SFTP user |
| `SftpKey` | file path | Private key file (SftpType `Key`) |
| `FileMask` | RegEx **or** Perl | File mask; may be a Perl snippet returning a RegEx string |
| `FileDateCheck` | `Y`/`N` | Filter files by creation/modification date |
| `FileCreationDate` | date / range | Mandatory if `FileDateCheck:Y`. `YYYY[-MM-DD HH24-MI-SS]`, one date or `date1&datedate2` range |
| `SubDirCheck` | `Y`/`N` | Recurse into sub-directories |
| `SizeCheck` | `Y`/`N` | Ensure file size is stable (20s delay per run) before processing |
| `CtlFileCheck` | `Y`/`N` | Require a zero-size control file before processing |
| `CtlFileExtension` | extension | Extension of the control file |
| `GzipOutput` | `Y`/`N` | `Y` input is gzipped, uncompress into target |
| `GzipInput` | `Y`/`N` | `Y` gzip the file in the target folder |
| `ArchiveCheck` | `Y`/`N` | Archive the original raw file |
| `ArchiveDir` | dir path | Archive directory |
| `LogMode` | `Full`/`Basic`/`None` | Log detail level (`None` disables file logging) |
| `LogDir` | dir path | Log directory |
| `LogFile` | file name | Log file name |
| `Notification` | `Y`/`N` | Send an email notification on errors |
| `NotificationSender` | email | Sender address (must be accepted by your SMTP relay) |
| `NotificationRe` | email(s) | Recipients (comma-separated) |
| `NotificationCc` | email(s) | CC recipients (comma-separated) |
| `NotificationMethod` | `smtp` | Constant |
| `NotificationServer` | host | SMTP server (default port 25) |

### Example `.param`

```
InputDir:/srv/export/
OutputDir:/data/target/input/
KeepInput:Y
SftpCheck:Y
SftpType:Key
SftpPassFile:None
SftpHost:192.0.2.10
SftpUser:sftpuser
SftpKey:/home/user/.ssh/id_rsa
FileMask:^DR_P11.*
FileDateCheck:N
FileCreationDate:
SubDirCheck:N
SizeCheck:N
CtlFileCheck:N
CtlFileExtension:NONE
GzipOutput:N
GzipInput:N
ArchiveCheck:N
ArchiveDir:/data/archive/
LogMode:Full
LogDir:/var/log/filetransfer/
LogFile:example.log
Notification:Y
NotificationSender:transfer@example.com
NotificationRe:ops@example.com
NotificationCc:transfer@example.com
NotificationMethod:smtp
NotificationServer:smtp.example.com
```

## Scheduling (cron)

```
# Weekly - every Sunday at 8:30
30 8 * * 0 /opt/filetransfer/bin/file_tran.pl /opt/filetransfer/param/example.param

# Every 5 minutes
*/5 * * * * /opt/filetransfer/bin/file_tran.pl /opt/filetransfer/param/job.param
```

## Logging

Each processed file is logged with process id, date and time. For every file,
its creation/modification timestamp is written to the log **before** the file is
transferred, e.g.:

```
4731: 20/10/26 20:55:23 [ File DR_P11_sample.dat creation/modification date (before transfer): 2026-10-18 09:15:30 -> transferring to /.../out/ ]
```

## Changelog

### v0.10
- A file is deleted from the input (`KeepInput:N`, also its control file) only after it was
  transferred completely to **every** output directory (and archived, when `ArchiveCheck:Y`).
  If any step fails the file stays in the input and is picked up again on the next run; the log
  says `File ... was NOT deleted from input because it was not transferred successfully`.
- Every error (copy, rename, gzip/gunzip, archive, delete, `chdir`) is written to the log as
  `ERROR: ...` and, with `Notification:Y`, sent in the notification e-mail at the end of the run.
  Before, most of these errors only reached the log.
- Half-written `tmp_` files are removed when a copy or rename fails.
- `gzip`/`gunzip` are called without the shell and their exit status is checked.

### v0.09
- Fixed SFTP connection check (`$sftp->error eq '0'` wrongly reported errors on
  successful connections).
- Fixed date-length comparisons that used assignment (`=`) instead of equality
  (`== 4`).
- Fixed date `substr` offsets that started at position 1 and dropped the first
  character of the date string.
- Fixed `printf` log call that treated the message as a format string (`%` in a
  file name corrupted the log); now uses `print`.
- Replaced fragile shell calls (`ls -l1`, `find -printf`) with Perl `stat`.
- Atomic writes now use `File::Copy::move` instead of `system("mv ...")` (works
  with spaces and special characters in paths/file names).
- Added mandatory logging of the file creation/modification date before every
  transfer, independent of `FileDateCheck`.
- Added `LogMode:None` support and removed stray debug output to STDOUT.
