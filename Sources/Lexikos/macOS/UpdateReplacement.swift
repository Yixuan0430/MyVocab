import Foundation

enum UpdateReplacement {
    static let script = #"""
    while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
    [ ! -e "$5" ] || exit 1
    [ "$2" = "$4" ] || [ ! -e "$4" ] || exit 1
    /bin/mv "$2" "$5" || exit 1
    if /bin/mv "$3" "$4"; then
        if [ -n "${6:-}" ]; then
            case "$4" in
                "$6"|"$6"/*) ;;
                *)
                    case "$5" in
                        "$6"|"$6"/*) ;;
                        *) /bin/rm -rf "$6" ;;
                    esac
                    ;;
            esac
        fi
        if [ "${MYVOCAB_UPDATE_TEST:-0}" != "1" ]; then /usr/bin/open "$4"; fi
        exit 0
    fi
    /bin/mv "$5" "$2" || exit 2
    exit 1
    """#
}
