# bash completion for slipway
# source this file from your ~/.bashrc, or symlink into /usr/local/etc/bash_completion.d/.

_slipway() {
  local cur prev words cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subs="claim reclaim ensure get release list conflicts doctor caddy reserved help"
  local registry="${SLIPWAY_REGISTRY:-$HOME/.config/slipway/registry.json}"

  _slipway_apps() {
    if [[ -f "$registry" ]] && command -v jq >/dev/null; then
      jq -r '.apps | keys[]' "$registry" 2>/dev/null
    fi
  }

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subs" -- "$cur") )
    return 0
  fi

  local sub="${COMP_WORDS[1]}"
  case "$sub" in
    get|release|reclaim|ensure|caddy)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_slipway_apps)" -- "$cur") )
        return 0
      fi
      ;;
    list)
      COMPREPLY=( $(compgen -W "--json --tsv --table" -- "$cur") )
      return 0
      ;;
    claim)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--dry-run --json" -- "$cur") )
      fi
      return 0
      ;;
    reserved)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "list add remove --json" -- "$cur") )
      fi
      return 0
      ;;
  esac
}
complete -F _slipway slipway
