#!/usr/bin/env python3
import os
import sys
import subprocess
import shutil

def run_cmd(cmd, check=True):
    print(f"\n[+] Running: {cmd}")
    try:
        # Using shell=True for simple command execution matching terminal behavior
        result = subprocess.run(cmd, shell=True, check=check, text=True)
        return result.returncode == 0
    except subprocess.CalledProcessError as e:
        print(f"[-] Command failed with exit code {e.returncode}: {cmd}", file=sys.stderr)
        if check:
            sys.exit(e.returncode)
        return False

def get_ubuntu_codename():
    try:
        with open("/etc/os-release", "r") as f:
            for line in f:
                if line.startswith("VERSION_CODENAME="):
                    return line.strip().split("=")[1].strip('"')
    except Exception:
        pass
    return None

def main():
    if os.geteuid() != 0:
        print("[-] This script must be run as root (with sudo).", file=sys.stderr)
        sys.exit(1)

    print("====================================================")
    print("      VIRTUALBOX CLEAN & FRESH INSTALLER            ")
    print("====================================================")

    # Step 1: Clean up broken apt/dpkg installations
    print("\n[*] Cleaning up previous broken VirtualBox installations...")
    run_cmd("apt purge -y virtualbox virtualbox-dkms virtualbox-qt", check=False)
    run_cmd("apt autoremove -y", check=False)
    run_cmd("dpkg --configure -a", check=False)

    # Step 2: Install core build-essential headers needed for compiling modules
    print("\n[*] Installing compilation prerequisites & system headers...")
    run_cmd("apt update")
    run_cmd("apt install -y build-essential dkms linux-headers-$(uname -r) wget")

    # Step 3: Set up official Oracle VirtualBox repository to get the latest working version
    codename = get_ubuntu_codename()
    if not codename:
        print("[-] Could not detect Ubuntu codename. Defaulting repository to 'noble' (24.04).", file=sys.stderr)
        codename = "noble"
    
    print(f"\n[*] Setting up official VirtualBox repository for Ubuntu '{codename}'...")
    
    # Download official repository signing key
    key_url = "https://www.virtualbox.org/download/oracle_vbox_2016.asc"
    key_path = "/usr/share/keyrings/oracle-virtualbox-2016.gpg"
    
    # Safely pull and de-armor the key into the modern keyrings directory
    run_cmd(f"wget -O- {key_url} | gpg --dearmor --yes -o {key_path}")
    
    # Write the repository file
    repo_line = f"deb [arch=amd64 signed-by={key_path}] https://download.virtualbox.org/virtualbox/debian {codename} contrib\n"
    repo_file = "/etc/apt/sources.list.d/virtualbox.list"
    
    with open(repo_file, "w") as f:
        f.write(repo_line)
    print(f"[+] Repository file created at {repo_file}")

    # Step 4: Install the latest VirtualBox release
    print("\n[*] Syncing repositories and installing the latest official VirtualBox...")
    run_cmd("apt update")
    
    # Installing virtualbox-7.1 as the latest modern stable branch
    run_cmd("apt install -y virtualbox-7.1")

    # Step 5: Add current user to vboxusers group
    # Note: Since script runs as sudo/root, we must find the real user who invoked sudo
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        print(f"\n[*] Adding user '{sudo_user}' to the 'vboxusers' group...")
        run_cmd(f"usermod -aG vboxusers {sudo_user}")
        print("[+] Group membership updated. (Note: You may need to log out and back in for group changes to fully apply).")
    else:
        print("\n[!] Could not automatically determine the regular user to add to the 'vboxusers' group.")

    print("\n====================================================")
    print("[+] VirtualBox installation process completed!")
    print("[*] If your machine uses UEFI Secure Boot, you may be prompted to reboot and authorize a MOK key.")
    print("====================================================")

if __name__ == "__main__":
    main()
