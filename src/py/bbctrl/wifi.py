# WiFi status and scanning via NetworkManager (Ubuntu) with a fallback to
# iwlist/iw (Raspbian).  Must agree with the backend chosen by config-wifi.

import subprocess

import iw_parse


def nm_running():
    try:
        out = subprocess.check_output(
            ['nmcli', '-t', '-f', 'RUNNING', 'general'],
            stderr = subprocess.DEVNULL)
        return out.decode().strip() == 'running'

    except (OSError, subprocess.CalledProcessError): return False


def split_terse(line):
    # Split an nmcli terse line on ':', honoring '\:' and '\\' escapes
    fields = ['']
    escaped = False

    for c in line:
        if escaped:
            fields[-1] += c
            escaped = False
        elif c == '\\': escaped = True
        elif c == ':': fields.append('')
        else: fields[-1] += c

    return fields


def nm_scan(ifname = 'wlan0'):
    out = subprocess.check_output(
        ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY,CHAN,FREQ,BSSID,MODE',
         'device', 'wifi', 'list', 'ifname', ifname, '--rescan', 'auto'],
        stderr = subprocess.DEVNULL).decode('utf-8', 'replace')

    networks = []
    for line in out.splitlines():
        fields = split_terse(line)
        if len(fields) != 7: continue
        ssid, signal, security, chan, freq, bssid, mode = fields

        # Same keys as iw_parse.get_parsed_cells()
        networks.append({
            'Name': ssid,
            'Quality': signal,
            'Encryption': security if security not in ('', '--') else 'Open',
            'Channel': chan,
            'Frequency': freq,
            'Address': bssid,
            'Mode': mode,
            'Signal Level': signal,
            'Noise Level': '',
            'Bit Rates': '',
        })

    networks.sort(key = lambda n: -int(n['Quality'] or 0))
    return networks


def scan_networks(ifname = 'wlan0'):
    if nm_running(): return nm_scan(ifname)

    lines = iw_parse.call_iwlist(ifname).decode('utf-8').split('\n')
    return iw_parse.get_parsed_cells(lines)


def get_active_ssid(ifname = 'wlan0'):
    if nm_running():
        out = subprocess.check_output(
            ['nmcli', '-t', '-e', 'no', '-f', 'ACTIVE,SSID', 'device', 'wifi',
             'list', 'ifname', ifname, '--rescan', 'no'],
            stderr = subprocess.DEVNULL).decode('utf-8', 'replace')

        for line in out.splitlines():
            if line.startswith('yes:'): return line[4:]

        return None

    out = subprocess.check_output(['iw', 'dev', ifname, 'info']).decode()
    for line in out.splitlines():
        words = line.split()
        if words and words[0] == 'ssid': return ' '.join(words[1:])

    return None
