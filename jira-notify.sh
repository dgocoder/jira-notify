parse_jira_key_array() {
    # must save as ISSUE_KEYS='["CC-4"]'
    # see https://jqplay.org/s/TNq7c5ctot
    ISSUE_KEYS=$(cat $GITHUB_EVENT_PATH | jq '[.commits[].message | scan("([A-Z]{2,30}-[0-9]+)")   | .[] ]')
    if [ "$ISSUE_KEYS" == "[]" ]; then
        # No issue keys found.
        echo "No issue keys found. This build does not contain a match for a Jira Issue. Please add your issue ID to the commit message or within the branch name."
        exit 0
    fi
}
generate_json_payload_deployment() {
    echo "Update Jira with status: ${2}"
    if [[ "${1}" == 'dev' ]]; then
        ENV_TYPE='development'
    elif [[ "${1}" == 'qa' ]]; then
        ENV_TYPE='testing'
    elif [[ "${1}" == 'stg' ]]; then
        ENV_TYPE='staging'
    elif [[ "${1}" == 'prod' ]]; then
        ENV_TYPE='production'
    else
        ENV_TYPE='unmapped'
    fi
    iso_time=$(date '+%Y-%m-%dT%T%z' | sed -e 's/\([0-9][0-9]\)$/:\1/g')
    echo {} | jq \
        --arg time_str "$(date +%s)" \
        --arg lastUpdated "${iso_time}" \
        --arg state "${2}" \
        --arg buildNumber "${GITHUB_RUN_ID}" \
        --arg pipelineNumber "${GITHUB_RUN_ID}" \
        --arg projectName "${GITHUB_REPOSITORY}" \
        --arg url "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
        --arg commit "${GITHUB_SHA}" \
        --arg refUri "${GITHUB_SERVER_URL}/tree/${GITHUB_HEAD_REF//\//-}" \
        --arg repositoryUri "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}" \
        --arg branchName "${GITHUB_HEAD_REF##*/}" \
        --arg repoName "${GITHUB_REPOSITORY}" \
        --arg pipelineDisplay "#${GITHUB_RUN_ID} ${GITHUB_REPOSITORY}" \
        --arg deployDisplay "#${GITHUB_RUN_ID} ${GITHUB_REPOSITORY} - ${1}" \
        --arg description "${GITHUB_REPOSITORY} #${GITHUB_RUN_ID} ${1}" \
        --arg envId "${1}" \
        --arg envName "${1}" \
        --arg envType "${ENV_TYPE}" \
        --argjson issueKeys "${ISSUE_KEYS}" \
        '
  ($time_str | tonumber) as $time_num |
  {
    "deployments": [
      {
        "schemaVersion": "1.0",
        "pipeline": {
          "id": $repoName,
          "displayName": $pipelineDisplay,
          "url": $url
        },
        "deploymentSequenceNumber": $pipelineNumber,
        "updateSequenceNumber": $time_str,
        "displayName": $deployDisplay,
        "description": $description,
        "url": $url,
        "state": $state,
        "lastUpdated": $lastUpdated,
        "associations": [
          {
            "associationType": "issueKeys",
            "values": $issueKeys
          }
        ],
        "environment":{
          "id": $envId,
          "displayName": $envName,
          "type": $envType
        }
      }
    ]
  }
  ' >/tmp/jira-status.json
}

post_to_jira() {

    HTTP_STATUS=$(curl \
        -u "${CIRCLE_TOKEN}:" \
        -s -w "%{http_code}" -o /tmp/curl_response.txt \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST "https://circleci.com/api/v1.1/project/github/${GITHUB_REPOSITORY}/jira/deployment" --data @/tmp/jira-status.json)

    echo "Results from Jira: "
    if [ "${HTTP_STATUS}" != "200" ]; then
        echo "Error calling Jira, result: ${HTTP_STATUS}" >&2
        jq '.' /tmp/curl_response.txt
        exit 1
    fi

    case "<<parameters.job_type>>" in
    "build")
        if jq -e '.unknownIssueKeys[0]' /tmp/curl_response.txt >/dev/null; then
            echo "ERROR: unknown issue key"
            jq '.' /tmp/curl_response.txt
            exit 1
        fi
        ;;
    "deployment")
        if jq -e '.unknownAssociations[0]' /tmp/curl_response.txt >/dev/null; then
            echo "ERROR: unknown association"
            jq '.' /tmp/curl_response.txt
            exit 1
        fi
        if jq -e '.rejectedDeployments[0]' /tmp/curl_response.txt >/dev/null; then
            echo "ERROR: Deployment rejected"
            jq '.' /tmp/curl_response.txt
            exit 1
        fi
        ;;
    esac

    # If reached this point, the deployment was a success.
    echo
    jq '.' /tmp/curl_response.txt
    echo
    echo
    echo "Success!"
}

parse_jira_key_array
if [[ "$ISSUE_KEYS" != "[]" ]]; then
    generate_json_payload_deployment $1 $2
    cat /tmp/jira-status.json
    post_to_jira
fi
