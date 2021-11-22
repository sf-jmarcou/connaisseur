set -euo pipefail

# This script is expected to be called from the root folder of Connaisseur
declare -A DEPLOYMENT_RES=(["VALID"]="0" ["INVALID"]="0")
RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m"
SUCCESS="${GREEN}SUCCESS${NC}"
FAILED="${RED}FAILED${NC}"
EXIT="0"
WOLIST=("CronJob" "DaemonSet" "Deployment" "Job" "Pod" "ReplicaSet" "ReplicationController" "StatefulSet")

### SINGLE TEST CASE ####################################
single_test() { # ID TXT TYP REF NS MSG RES
  echo -n "[$1] $2"
  if [[ "$3" == "deploy" ]]; then
    kubectl run pod-$1 --image="$4" --namespace="$5" >output.log 2>&1 || true
  elif [[ "$3" == "workload" ]]; then
    envsubst <tests/integration/workload-objects/$4.yaml | kubectl apply -f - >output.log 2>&1 || true
  else
    kubectl apply -f $4 >output.log 2>&1 || true
  fi
  if [[ ! "$(cat output.log)" =~ "$6" ]]; then
    echo -e ${FAILED}
    echo "::group::Output"
    cat output.log
    kubectl logs -n connaisseur -lapp.kubernetes.io/instance=connaisseur
    echo "::endgroup::"
    EXIT="1"
  else
    echo -e "${SUCCESS}"
  fi

  if [[ $7 != "null" ]]; then
    DEPLOYMENT_RES[$7]=$((${DEPLOYMENT_RES[$7]} + 1))
  fi
}

### MULTI TEST CASE FROM FILE ####################################
multi_test() { # TEST_CASE: key in the `test_cases` dict in the cases.yaml
  test_cases=$(yq e -o=json ".test_cases.$1" tests/integration/cases.yaml)
  len=$(echo ${test_cases} | jq 'length')
  for i in $(seq 0 $(($len - 1))); do
    test_case=$(echo ${test_cases} | jq ".[$i]")
    ID=$(echo ${test_case} | jq -r ".id")
    TEST_CASE_TXT=$(echo ${test_case} | jq -r ".txt")
    TYPE=$(echo ${test_case} | jq -r ".type")
    REF=$(echo ${test_case} | jq -r ".ref")
    NAMESPACE=$(echo ${test_case} | jq -r ".namespace")
    EXP_MSG=$(echo ${test_case} | jq -r ".expected_msg")
    EXP_RES=$(echo ${test_case} | jq -r ".expected_result")
    single_test "${ID}" "${TEST_CASE_TXT}" "${TYPE}" "${REF}" "${NAMESPACE}" "${EXP_MSG}" "${EXP_RES}"
  done
}

### WORKLOAD TEST ####################################
workload_test() { # WORKLOAD_KIND
  export KIND=$1
  export APIVERSION=$(kubectl api-resources | awk -v KIND=${KIND} '{ if($NF == ""KIND"") print $(NF-2);}')

  # UNSIGNED
  export TAG=unsigned
  echo "::group::${KIND}_${APIVERSION}_${TAG}.yaml"
  envsubst <tests/integration/workload-objects/${KIND}.yaml | cat
  echo "::endgroup::"
  single_test "w_${KIND}_${APIVERSION}_${TAG}" "Testing ${KIND} using ${APIVERSION} and ${TAG} image..." "workload" "${KIND}" "deafult" "Unable to find signed digest for image docker.io/securesystemsengineering/testimage:unsigned." "null"

  # SIGNED
  export TAG=signed
  echo "::group::${KIND}_${APIVERSION}_${TAG}.yaml"
  envsubst <tests/integration/workload-objects/${KIND}.yaml | cat
  echo "::endgroup::"
  single_test "w_${KIND}_${APIVERSION}_${TAG}" "Testing ${KIND} using ${APIVERSION} and ${TAG} image..." "workload" "${KIND}" "deafult" " created" "null"
}

### STRESS TEST ####################################
stress_test() { #
  NUMBER_OF_INSTANCES=100
  echo -n 'Testing Connaisseur with complex requests...'
  kubectl apply -f tests/integration/deployments/stresstest.yaml >output.log 2>&1 || true
  if [[ ! ("$(cat output.log)" =~ 'deployment.apps/redis-with-many-instances created' && "$(cat output.log)" =~ 'pod/pod-with-many-containers created' && "$(cat output.log)" =~ 'pod/pod-with-many-containers-and-init-containers created' && "$(cat output.log)" =~ 'pod/pod-with-some-containers-and-init-containers created' && "$(cat output.log)" =~ 'pod/pod-with-coinciding-containers-and-init-containers created') ]]; then
    echo -e ${FAILED}
    echo "::group::Output"
    cat output.log
    echo "::endgroup::"
    EXIT="1"
  else
    echo -e "${SUCCESS}"
  fi

  echo -n 'Cleaning up before second test...'
  kubectl delete all -ltest=stresstest >/dev/null
  echo -e "${SUCCESS}"

  echo -n 'Testing Connaisseur with many requests...'
  parallel --jobs 20 ./tests/integration/cause_load.sh {1} :::: <(seq ${NUMBER_OF_INSTANCES}) >output.log 2>&1 || true
  NUMBER_CREATED=$(cat output.log | grep "deployment[.]apps/redis-[0-9]* created" | wc -l || echo "0")
  if [[ ${NUMBER_CREATED} != "${NUMBER_OF_INSTANCES}" ]]; then
    echo -e ${FAILED}
    echo "::group::Output"
    echo "Only ${NUMBER_CREATED}/${NUMBER_OF_INSTANCES} pods were created."
    cat output.log
    echo "::endgroup::"
    EXIT="1"
  else
    echo -e "${SUCCESS}"
  fi
}

### INSTALLING CONNAISSEUR ####################################
install_make() {
  echo -n "Installing Connaisseur..."
  make install >/dev/null || {
    echo -e "${FAILED}"
    exit 1
  }
  echo -e "${SUCCESS}"
}

install_helm() {
  echo -n "Installing Connaisseur..."
  helm install connaisseur helm --atomic --create-namespace \
    --namespace connaisseur >/dev/null || {
    echo -e "${FAILED}"
    exit 1
  }
  echo -e "${SUCCESS}"
}

### UPGRADING CONNAISSEUR ####################################
upgrade_make() {
  echo -n 'Upgrading Connaisseur...'
  make upgrade >/dev/null || {
    echo -e ${FAILED}
    exit 1
  }
  echo -e "${SUCCESS}"
}

upgrade_helm() {
  echo -n 'Upgrading Connaisseur...'
  helm upgrade connaisseur helm -n connaisseur --wait >/dev/null || {
    echo -e ${FAILED}
    exit 1
  }
  echo -e "${SUCCESS}"
}

### UNINSTALLING CONNAISSEUR ####################################
uninstall_make() {
  echo -n 'Uninstalling Connaisseur...'
  make uninstall >/dev/null || {
    echo -e "${FAILED}"
    exit 1
  }
  echo -e "${SUCCESS}"
}

uninstall_helm() {
  echo -n 'Uninstalling Connaisseur...'
  helm uninstall connaisseur -n connaisseur &&
    kubectl delete ns connaisseur >/dev/null || {
    echo -e "${FAILED}"
    exit 1
  }
  echo -e "${SUCCESS}"
}

update_values() { # [EXPRESSION...]
  for update in "$@"; do
    yq e -i "${update}" helm/values.yaml
  done
}

debug_vaules() {
  echo "::group::values.yaml"
  cat helm/values.yaml
  echo "::endgroup::"
}

### RUN REGULAR INTEGRATION TEST ####################################
regular_int_test() {
  multi_test "regular"

  ### EDGE CASE TAG IN RELEASES AND TARGETS ####################################
  echo -n "[edge1] Testing edge case of tag defined in both targets and release json file..."
  DEPLOYED_SHA=$(kubectl get pod pod-rs -o yaml | yq e '.spec.containers[0].image' - | sed 's/.*sha256://')
  if [[ "${DEPLOYED_SHA}" != 'c5327b291d702719a26c6cf8cc93f72e7902df46547106a9930feda2c002a4a7' ]]; then
    echo -e "${FAILED}"
  else
    echo -e "${SUCCESS}"
  fi
  N=$(($N + 1))

  ### ALERTING TEST ####################################
  echo -n "Checking whether alert endpoints have been called successfully..."
  ENDPOINT_HITS="$(curl -s ${ALERTING_ENDPOINT_IP}:56243 --header 'Content-Type: application/json')"
  NUMBER_OF_DEPLOYMENTS=$((${DEPLOYMENT_RES["VALID"]} + ${DEPLOYMENT_RES["INVALID"]}))
  EXPECTED_ENDPOINT_HITS=$(jq -n \
    --argjson REQUESTS_TO_SLACK_ENDPOINT ${NUMBER_OF_DEPLOYMENTS} \
    --argjson REQUESTS_TO_OPSGENIE_ENDPOINT ${DEPLOYMENT_RES["VALID"]} \
    --argjson REQUESTS_TO_KEYBASE_ENDPOINT ${DEPLOYMENT_RES["INVALID"]} \
    '{
  "successful_requests_to_slack_endpoint":$REQUESTS_TO_SLACK_ENDPOINT,
  "successful_requests_to_opsgenie_endpoint": $REQUESTS_TO_OPSGENIE_ENDPOINT,
  "successful_requests_to_keybase_endpoint": $REQUESTS_TO_KEYBASE_ENDPOINT
  }')
  diff <(echo "$ENDPOINT_HITS" | jq -S .) <(echo "$EXPECTED_ENDPOINT_HITS" | jq -S .) >diff.log 2>&1 || true
  if [[ -s diff.log ]]; then
    echo -e "${FAILED}"
    echo "::group::Alerting endpoint diff:"
    cat diff.log
    echo "::endgroup::"
    EXIT="1"
  else
    echo -e "${SUCCESS}"
  fi
}

### COSIGN TEST ####################################
cosign_int_test() {
  multi_test "cosign"
}

### NAMESPACE VALIDATION TEST ####################################
namespace_val_int_test() {
  echo -n "Creating namespaces..."
  kubectl create namespace ignoredns >/dev/null
  kubectl label ns ignoredns securesystemsengineering.connaisseur/webhook=ignore >/dev/null
  kubectl create namespace validatedns >/dev/null
  kubectl label ns validatedns securesystemsengineering.connaisseur/webhook=validate >/dev/null
  echo -e "${SUCCESS}"

  multi_test "ignore-namespace-val"
  update_values '.namespacedValidation.mode="validate"'
  upgrade_make
  multi_test "validate-namespace-val"
}

### DEPLOYMENT TEST ####################################
deployment_int_test() {
  multi_test "deployment"
}

### PRECONFIG TEST ####################################
pre_config_int_test() {
  multi_test "pre-config"
}

case $1 in
"regular")
  install_make
  regular_int_test
  uninstall_make
  ;;
"cosign")
  install_make
  cosign_int_test
  ;;
"namespace-val")
  update_values '.namespacedValidation.enabled=true'
  install_make
  namespace_val_int_test
  ;;
"deployment")
  update_values '.policy += {"pattern": "docker.io/library/*:*", "validator": "dockerhub-basics", "with": {"trust_root": "docker-official"}}'
  install_make
  deployment_int_test
  ;;
"pre-config")
  install_helm
  pre_config_int_test
  uninstall_helm
  ;;
"pre-and-workload")
  install_make
  pre_config_int_test
  for wo in "${WOLIST[@]}"; do
    workload_test "${wo}"
  done
  ;;
"stress-test")
  install_make
  stress_test
  ;;
"all")
  install_make
  regular_int_test
  cosign_int_test
  update_values '.namespacedValidation.enabled=true'
  upgrade_make
  namespace_val_int_test
  update_values '.namespacedValidation.enabled=false' '.policy += {"pattern": "docker.io/library/*:*", "validator": "dockerhub-basics", "with": {"trust_root": "docker-official"}}'
  upgrade_make
  deployment_int_test
  uninstall_make
  ;;
*)
  EXIT="1"
  ;;
esac

if [[ $EXIT == "1" ]]; then
  exit 1
fi
