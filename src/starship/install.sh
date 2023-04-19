#!/bin/bash

USE_NERD_FONT_SYMBOLS="${USE_NERD_FONT_SYMBOLS:-"true"}"
USERNAME="${USERNAME:-"automatic"}"
INSTALL_EXA="${INSALL_EXA:-"true"}"

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

apt_get_update()
{
    echo "Running apt-get update..."
    apt-get update -y
}

apply_exa_alias()
{
    echo 'alias ls="exa --icons"' >> "$@"
    echo 'alias ll="ls -l"' >> "$@"
    echo 'alias lla="ll -a"' >> "$@"
}

if [ "${INSTALL_EXA}" = "true" ]; then
    apt_get_update
    echo "Installing exa..."
    apt-get -y install --no-install-recommends exa
    apt-get clean -y
    rm -rf /var/lib/apt/lists/*
fi

# Ensure curl is installed
if ! type curl > /dev/null 2>&1; then
    apt_get_update
    echo "Installing curl..."
    apt-get -y install --no-install-recommends curl
    # Clean up
    apt-get clean -y
    rm -rf /var/lib/apt/lists/*
fi

# Install starship
if ! type starship > /dev/null 2>&1; then
    curl -sS https://starship.rs/install.sh | sh -s -- --yes
fi

# If in automatic mode, determine if a user already exists, if not use vscode
if [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("devcontainer" "vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ]; then
    USERNAME=root
    USER_UID=0
    USER_GID=0
fi

if [ "${USERNAME}" = "root" ]; then
    user_rc_path="/root"
else
    user_rc_path="/home/${USERNAME}"
    if [ ! -d "${user_rc_path}" ]; then
        mkdir -p "${user_rc_path}"
        chown ${USERNAME}:${USERNAME} "${user_rc_path}"
    fi
fi

# Restore user .bashrc / .profile / .zshrc defaults from skeleton file if it doesn't exist or is empty
possible_rc_files=( ".bashrc" ".profile" ".zshrc" )
for rc_file in "${possible_rc_files[@]}"; do
    if [ -f "/etc/skel/${rc_file}" ]; then
        if [ ! -e "${user_rc_path}/${rc_file}" ] || [ ! -s "${user_rc_path}/${rc_file}" ]; then
            cp "/etc/skel/${rc_file}" "${user_rc_path}/${rc_file}"
            chown ${USERNAME}:${USERNAME} "${user_rc_path}/${rc_file}"
        fi
    fi
done

# Add RC snippet and custom bash prompt
if [ "${RC_SNIPPET_ALREADY_ADDED}" != "true" ]; then
    echo "${user_rc_path}"
    echo 'eval "$(starship init bash)"' >> "${user_rc_path}/.bashrc"
    if type zsh > /dev/null 2>&1; then
        echo 'eval "$(starship init zsh)"' >> "${user_rc_path}/.zshrc"
    fi
    if [ "${USERNAME}" != "root" ]; then
        echo 'eval "$(starship init bash)"' >> "/root/.bashrc"
        if type zsh > /dev/null 2>&1; then
            echo 'eval "$(starship init zsh)"' >> "/root/.zshrc"
        fi
        chown ${USERNAME}:${USERNAME} "${user_rc_path}/.bashrc"
    fi
    if [ "${USE_NERD_FONT_SYMBOLS}" = "true" ]; then
        mkdir -p "${user_rc_path}/.config"
        starship preset nerd-font-symbols > "${user_rc_path}/.config/starship.toml"
    fi
    if type exa > /dev/null 2>&1; then
        apply_exa_alias "${user_rc_path}/.bashrc"
        if type zsh > /dev/null 2>&1; then
            apply_exa_alias "${user_rc_path}/.zshrc"
        fi
        if [ "${USERNAME}" != "root" ]; then
            apply_exa_alias "/root/.bashrc"
            if type zsh > /dev/null 2>&1; then
                apply_exa_alias "/root/.zshrc"
            fi
            chown ${USERNAME}:${USERNAME} "${user_rc_path}/.bashrc"
        fi
    fi
    RC_SNIPPET_ALREADY_ADDED="true"
fi

echo "Done!"
