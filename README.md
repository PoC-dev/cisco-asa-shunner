This is a program meant to extend the functionality of [fail2ban](https://github.com/fail2ban/fail2ban) on Linux to instruct a Cisco firewall running ASA code to *shun* IP addresses instead of blocking with local iptables firewall rules.

Fail2ban is a daemon to ban hosts that cause multiple authentication errors. It's often found on exposed Linux hosts.

Cisco ASA is a proprietary combination of hardware and software for a rather flexible and mainly command line based firewall solution. *Shunning* a host ist an action which is usually done on the ASA command line to completely ignore packets from a given IP address on any given interface.

## License
All parts of this application are subject to the GNU General Public License v2. A copy of the license is included for your convenience.

## Files
- *cisco-asa-shunner.asacreds* hosts the ASA's login credentials. It's vital to make sure this file is **only** readable by *root* (or whatever user *fail2ban* is running as).
- *cisco-asa-shunner.conf* is the *fail2ban* related configuration, instructing the fail2ban core how to run the perl script for a given ban or unban action.
- *cisco-asa-shunner.pl* is the main program, interactively logging into the ASA and issuing shun and no shun commands as directed.
- *LICENSE* is a copy of the GNU General Public License v2, applying to the files in this project.
- *README.md* is the file you're currently reading.

## Installation
Installation instructions have been tested on Debian Linux 12.

The Perl script requires the expect perl module to be installed. You can run `apt-get install libexpect-perl` to obtain this on Debian.

### Cisco ASA
First, prepare your Cisco ASA to allow just the commands `shun`, `no shun`, and `show shun`, and nothing else in a restricted command line. `Exit` for terminating a session is implicitly always allowed.

We're creating a user *fail2ban* for this purpose and assign the privilege level 5, a completely arbitrary number.

The given AAA configuration is what I'm using as default on any ASA I install. Especially *auto-enable* is something I like a lot. If this breaks other automatisms, you need to merge configurations until both work.

If you cannot use *auto-enable*, configure an according enable password into *cisco-asa-shunner.asacreds*.

**Note**: The `enable` based code path is largely untested.
```
conf t
!
aaa authentication ssh console LOCAL
aaa authentication telnet console LOCAL
aaa authentication http console LOCAL
aaa authentication serial console LOCAL
aaa authentication enable console LOCAL
aaa authorization command LOCAL
aaa authorization exec LOCAL auto-enable
!
username fail2ban password mydirtylittlesecret privilege 5
!
privilege cmd level 5 mode exec command shun
privilege show level 5 mode exec command shun
!
end
write
```
- Please change the *fail2ban* user's password to something more secure.
- The ASA has to accept *ssh* connections from the IP address of the *fail2ban* host.

**Test now** if you can connect with the given credentials to the ASA and successfully can issue the `shun`, `no shun`, and `show shun` commands. Ideally, you test as the same user as *fail2ban* runs. This gives you the chance to add the ASA's host key to the user's *~/.ssh/known_hosts* file.

### Fail2ban
You need to be *root* for installation. Use single `sudo` in front of each command, or make your life easier by using `sudo -s` to obtain a root shell.

First, copy files to their destination:
```
install -g root -m 600 -o root -p cisco-asa-shunner.asacreds /etc/fail2ban
install -g root -m 644 -o root -p cisco-asa-shunner.conf /etc/fail2ban/action.d
install -g root -m 755 -o root -p cisco-asa-shunner.pl /etc/fail2ban/action.d
```
Now, edit */etc/fail2ban/cisco-asa-shunner.asacreds* to reflect the ASA configuration you've done above.

Finally, configure the newly available action into *fail2ban*. Edit */etc/fail2ban/jail.d/local-settings.conf*:
```
[DEFAULT]
banaction = cisco-asa-shunner
```
Finally, restart *fail2ban*.

**Note**: The banaction defined in `[DEFAULT]` as shown above does **only** override banactions being defined as default in the global jail configuration. If you find a particular jail you want to use in */etc/fail2ban/jail.conf*, see if it has a `banaction` configured. If yes, you need to override this banaction in */etc/fail2ban/jail.d/local-settings.conf* also.

## Diagnostics
- Watch *fail2ban* logs to see errors.
- According to *cisco-asa-shunner.conf*, `logger` with facility *user* (default) is used to send an entry to syslog when an action is done. Refer to your Linux distribution's documentation about how and where to obtain logs. This helps in knowing if the shunner script is actually called.
- `show shun` on ASA should show entries if something triggered *fail2ban*.
- The list of shuns should match the output of `fail2ban-client banned`. **Note**: One IP address can be shunned just once but might have triggered multiple jails of *fail2ban*.

----
2024-07-06 poc@pocnet.net
