main() {
  local command=${1:-help}
  shift || true
  case "$command" in
    install) command_install "$@" ;;
    init) command_init "$@" ;;
    proxy) command_proxy "$@" ;;
    list) command_list "$@" ;;
    status) command_status "$@" ;;
    acme) command_acme "$@" ;;
    analyze|goaccess) command_analyze "$@" ;;
    cron) command_cron "$@" ;;
    geoip2) command_geoip2 "$@" ;;
    ondemand) command_ondemand "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "Unknown command: $command" ;;
  esac
}

main "$@"
