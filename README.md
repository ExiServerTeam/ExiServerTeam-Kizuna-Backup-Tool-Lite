# ExiServerTeam-Kizuna-Backup-Tool-Lite
A reliable and fully automated multi-functional backup Shell script (Lite Edition).
##1. Basic Usage

Kizuna-Backup LITE is a simple backup tool that works with command-line arguments only (no configuration file required).

Basic command:
  ./kizuna-lite.sh <target_directory> <user@host> <remote_path>

Example:
  ./kizuna-lite.sh /home/user/data backup@192.168.1.100 /backup/data

##2. Options

  -m, --mode sync|archive   Backup mode (default: sync)
  -k, --key <key_file>      SSH private key
  -p, --port <port>         SSH port (default: 22)
  --dry-run                 Simulation mode (does not actually transfer)
  -h, --help                Show help

sync mode: rsync differential backup (fast, lightweight)
archive mode: tar.gz compressed backup (with SHA-256 integrity check)

##3. Examples

  # sync mode (basic)
  ./kizuna-lite.sh /home/user/data backup@192.168.1.100 /backup/data

  # archive mode (tar.gz compression)
  ./kizuna-lite.sh /var/www user@server.com /backup/www --mode archive

  # SSH private key and port specified
  ./kizuna-lite.sh /etc root@10.0.0.1 /backup/etc -k ~/.ssh/id_rsa -p 2222

  # Dry run (simulation)
  ./kizuna-lite.sh /home/user/data backup@192.168.1.100 /backup/data --dry-run

##4. Requirements

  - Bash 4.0 or higher
  - The following commands must be installed:
    ssh / rsync / tar / sha256sum / flock / awk / du
  - SSH key authentication is required (password authentication is not supported)

##5. Notes

  - The remote directory will be created automatically
  - This tool is provided as-is, use at your own risk

##6. PRO Version (Paid)

Kizuna-Backup PRO (500 JPY) includes the following advanced features:

  PRO features:
  - Configuration file (INI) management
  - Generation management (daily/weekly/monthly)
  - GPG encryption
  - Slack/Discord notifications
  - cron automation
  - Installation manual
  - Email support (1 year)

  For details and purchase: (https://exiserverteam.booth.pm/items/8724798)

##7. License

  This tool is free software.
  You are free to modify and redistribute it, but you must credit the original author (shige).

Author: shige

!Please note that we cannot be held responsible for any data loss or other damages caused by using this tool for backups.!
!You are free to modify and redistribute this tool. However, you must credit the original author (shige) upon redistribution.!
