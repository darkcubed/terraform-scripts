#!/bin/bash
echo "Starting $0"
PROVIDER=""
TYPE=""
OPTSPEC=":-:"
while getopts "${OPTSPEC}" OPT; do
   case "${OPT}" in
      -)
         case "${OPTARG}" in
            provider)
               PROVIDER="${!OPTIND}"
               OPTIND=$(( ${OPTIND} + 1 ))
               ;;
            provider=*)
               PROVIDER="${OPTARG#*=}"
               ;;
            type)
               TYPE="${!OPTIND}"
               OPTIND=$(( ${OPTIND} + 1 ))
               ;;
            type=*)
               TYPE="${OPTARG#*=}"
               ;;
         esac
         ;;
    esac
done
echo "PROVIDER: ${PROVIDER}"
echo "TYPE: ${TYPE}"
shift $((OPTIND-1))
echo "$@"
exit



packages='aptitude'
apt-get update && apt-get -y install $${packages}

echo "Done"
