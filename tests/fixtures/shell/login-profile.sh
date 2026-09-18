# Loaded by the real sandbox login shell, after /etc/profile.
printf '__initial__%s|%s__\n' "$PWD" "${HTTP_PROXY-}"
for variable in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; do
    printf '__environment__%s=%s__\n' "$variable" "${!variable-}"
done
cd /tmp || exit 92
export HTTP_PROXY=profile-proxy
export PATH="/profile-bin:$PATH"
unset HISTFILE
printf '__profile_complete__\n'
