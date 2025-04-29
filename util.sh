#!/bin/bash

# Exit on error, treat unset variables as an error, and prevent errors in pipelines from being hidden.
set -euo pipefail

# --- Configuration ---
PROXY_NAME="messages" # Name of the Apigee proxy
PROXY_MAIN_DIR="apigee/messages" # Subdirectory containing the 'apiproxy' folder
PROXY_SOURCE_SUBDIR="apiproxy" # The actual proxy source folder
PROXY_BUNDLE_NAME="${PROXY_NAME}.zip"

SERVICE_ACCOUNT_NAME="swim-reader"
TOPIC_NAME="swim-incoming"
SUBSCRIPTION_NAME="swim-api-sub"

# Path to the proxy endpoint definition (relative to script execution dir)
PROXY_ENDPOINT_DEF_FILE="${PROXY_MAIN_DIR}/${PROXY_SOURCE_SUBDIR}/proxies/default.xml"

# --- Check for required environment variables ---
: "${PROJECT_ID:?ERROR: PROJECT_ID environment variable is not set.}"
: "${APIGEE_ENV:?ERROR: APIGEE_ENV environment variable is not set.}"

# --- Check for jq ---
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed. Please install jq to continue."
    echo "See: https://stedolan.github.io/jq/download/"
    exit 1
fi

# --- Optional Flag Processing ---
PUBLISH_MESSAGE=false
if [[ "${1:-}" == "--publish" ]]; then
    PUBLISH_MESSAGE=true
    echo "INFO: --publish flag detected. A message will be published to the topic after deployment."
fi

echo "INFO: Starting Apigee proxy deployment script..."
echo "--------------------------------------------------"
echo "INFO: Project ID:       ${PROJECT_ID}"
echo "INFO: Apigee Environment: ${APIGEE_ENV}"
echo "INFO: Proxy Name:         ${PROXY_NAME}"
echo "INFO: Service Account:    ${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "INFO: Pub/Sub Topic:      ${TOPIC_NAME}"
echo "INFO: Pub/Sub Subscription: ${SUBSCRIPTION_NAME}"
echo "--------------------------------------------------"

# --- Define Fully Qualified Names ---
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
TOPIC_FQN="projects/${PROJECT_ID}/topics/${TOPIC_NAME}"
SUBSCRIPTION_FQN="projects/${PROJECT_ID}/subscriptions/${SUBSCRIPTION_NAME}"

# --- 1. Ensure Service Account exists ---
echo "INFO: Checking/Creating Service Account '${SERVICE_ACCOUNT_NAME}'..."
gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" --project "${PROJECT_ID}" &>/dev/null || \
    gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
        --display-name="Service account for Apigee Pub/Sub proxy to read messages" \
        --project "${PROJECT_ID}"
echo "INFO: Service Account '${SERVICE_ACCOUNT_EMAIL}' ensured."

# --- 2. Ensure Pub/Sub Topic exists ---
echo "INFO: Checking/Creating Pub/Sub Topic '${TOPIC_NAME}'..."
gcloud pubsub topics describe "${TOPIC_NAME}" --project "${PROJECT_ID}" &>/dev/null || \
    gcloud pubsub topics create "${TOPIC_NAME}" --project "${PROJECT_ID}"
echo "INFO: Pub/Sub Topic '${TOPIC_NAME}' ensured."

# --- 3. Ensure Pub/Sub Subscription exists ---
echo "INFO: Checking/Creating Pub/Sub Subscription '${SUBSCRIPTION_NAME}' for topic '${TOPIC_NAME}'..."
gcloud pubsub subscriptions describe "${SUBSCRIPTION_NAME}" --project "${PROJECT_ID}" &>/dev/null || \
    gcloud pubsub subscriptions create "${SUBSCRIPTION_NAME}" \
        --topic "${TOPIC_NAME}" \
        --topic-project "${PROJECT_ID}" \
        --project "${PROJECT_ID}" \
        --ack-deadline=60 # Adjust as needed, this is for pull subscription
echo "INFO: Pub/Sub Subscription '${SUBSCRIPTION_NAME}' ensured."

# --- 4. Grant Service Account permissions on the Subscription ---
echo "INFO: Granting Pub/Sub Subscriber role to '${SERVICE_ACCOUNT_EMAIL}' on subscription '${SUBSCRIPTION_NAME}'..."
gcloud pubsub subscriptions add-iam-policy-binding "${SUBSCRIPTION_NAME}" \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/pubsub.subscriber" \
    --project "${PROJECT_ID}" >/dev/null # Suppress output if binding already exists

#echo "INFO: Granting Pub/Sub Viewer role to '${SERVICE_ACCOUNT_EMAIL}' on subscription '${SUBSCRIPTION_NAME}'..."
#gcloud pubsub subscriptions add-iam-policy-binding "${SUBSCRIPTION_NAME}" \
#    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
#    --role="roles/pubsub.viewer" \
#    --project "${PROJECT_ID}" >/dev/null # Suppress output if binding already exists
#echo "INFO: Permissions granted."


# --- 5. Zip the Apigee proxy ---
echo "INFO: Zipping the proxy to include the '${PROXY_SOURCE_SUBDIR}' folder at the root of '${PROXY_BUNDLE_NAME}'..."
echo "INFO: The '${PROXY_SOURCE_SUBDIR}' folder will be taken from '${PROXY_MAIN_DIR}/${PROXY_SOURCE_SUBDIR}'."

# Change directory to the parent of 'apiproxy' (PROXY_MAIN_DIR).
# Then, zip the 'apiproxy' folder (PROXY_SOURCE_SUBDIR).
# The output path '../../${PROXY_BUNDLE_NAME}' places the zip in the script's original execution directory.
# Exclude common hidden version control files/folders. You can add other excludes if needed.
(cd "${PROXY_MAIN_DIR}" && zip -r "../../${PROXY_BUNDLE_NAME}" "${PROXY_SOURCE_SUBDIR}" -x "${PROXY_SOURCE_SUBDIR}/.git/*" -x "${PROXY_SOURCE_SUBDIR}/.hg/*" -x "${PROXY_SOURCE_SUBDIR}/.svn/*")

echo "INFO: Proxy bundle '${PROXY_BUNDLE_NAME}' created successfully with '${PROXY_SOURCE_SUBDIR}' at its root."

# --- 6. Import and Deploy Apigee Proxy (using curl) ---
echo "INFO: Acquiring access token (assuming 'gcloud auth print-access-token' is available)..."
ACCESS_TOKEN=$(gcloud auth print-access-token) # If gcloud is completely disallowed, this needs a different mechanism
if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "ERROR: Failed to acquire access token."
    echo "       If 'gcloud' is entirely disallowed, you'll need a manual OAuth 2.0 token generation flow for service accounts."
    exit 1
fi
echo "INFO: Access token acquired."


echo "INFO: Importing Apigee proxy '${PROXY_NAME}' from '${PROXY_BUNDLE_NAME}' using curl..."
echo "DEBUG: Executing curl command for proxy import..."

# We will capture the output and the HTTP status code from curl.
# Removed --fail so curl outputs the body even on HTTP error.
# -w appends the status code to the output, prefixed by a unique string.
HTTP_BODY_AND_STATUS=$(curl --show-error \
  -w "\nCURL_HTTP_STATUS_CODE:%{http_code}" \
  -X POST \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/apis?action=import&name=${PROXY_NAME}&validate=false" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${PROXY_BUNDLE_NAME}")

# Extract the body and status code
# The body is everything except the last line (our status code line)
HTTP_BODY=$(echo "${HTTP_BODY_AND_STATUS}" | sed '$d')
# The status code is the last line, with our prefix removed
HTTP_STATUS_CODE=$(echo "${HTTP_BODY_AND_STATUS}" | tail -n 1 | sed 's/CURL_HTTP_STATUS_CODE://')

# Assign the captured body to IMPORT_RESPONSE_JSON for subsequent logic if successful
IMPORT_RESPONSE_JSON="${HTTP_BODY}"

echo "DEBUG: Curl command finished."
echo "DEBUG: HTTP Status Code from import API: ${HTTP_STATUS_CODE}"
echo "DEBUG: Full API Response Body from import API:"
echo "${IMPORT_RESPONSE_JSON}" # Print the entire response body

# Check if the HTTP status code indicates an error
if [[ "${HTTP_STATUS_CODE}" -lt 200 || "${HTTP_STATUS_CODE}" -gt 299 ]]; then
    echo "ERROR: API call to import proxy failed with HTTP status code ${HTTP_STATUS_CODE}."
    echo "       The server's response (shown above) should contain more details."
    exit 1
fi

# If we've reached here, the HTTP status code was 2xx (success)
echo "INFO: API call for import returned HTTP ${HTTP_STATUS_CODE}."

# The existing checks for empty response or parsing failure will follow:
if [[ -z "$IMPORT_RESPONSE_JSON" ]]; then
    echo "ERROR: API response for import was empty, though HTTP status was ${HTTP_STATUS_CODE}."
    exit 1
fi

# The response for a successful import is the Apigee APIProxy resource JSON.
# It contains a 'revision' array (list of strings). The newly created revision is the last one.
IMPORTED_REVISION=$(echo "${IMPORT_RESPONSE_JSON}" | jq -r '.revision')

if [[ -z "$IMPORTED_REVISION" || "$IMPORTED_REVISION" == "null" ]]; then
    echo "ERROR: Could not determine imported revision number from API response."
    echo "Response was: ${IMPORT_RESPONSE_JSON}"
    exit 1
fi
echo "INFO: Proxy imported successfully via API. New revision is '${IMPORTED_REVISION}'."

echo "INFO: Deploying revision '${IMPORTED_REVISION}' of proxy '${PROXY_NAME}' to environment '${APIGEE_ENV}' using service account '${SERVICE_ACCOUNT_EMAIL}' via curl..."

# Construct the JSON payload for deployment, including the service account for the runtime.
DEPLOY_PAYLOAD_JSON="{\"serviceAccount\": \"${SERVICE_ACCOUNT_EMAIL}\"}"

# The API call to deploy a specific revision to an environment.
# 'override=true' allows deploying over an existing deployment of this proxy in the environment.
DEPLOY_RESPONSE_JSON=$(curl --fail -X POST \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${IMPORTED_REVISION}/deployments?override=true" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${DEPLOY_PAYLOAD_JSON}" \
  --silent)

if [[ $? -ne 0 || -z "$DEPLOY_RESPONSE_JSON" ]]; then
    echo "ERROR: curl command to deploy proxy revision failed or returned empty response."
    exit 1
fi

# A successful deployment initiation returns a Deployment resource JSON or an operation.
# We can check the 'state' field if a Deployment resource is returned directly.
DEPLOY_STATE=$(echo "${DEPLOY_RESPONSE_JSON}" | jq -r '.state // .name') # .state if direct, .name if LRO

if [[ -n "$DEPLOY_STATE" ]]; then
    echo "INFO: Proxy deployment initiated/completed via API. Reported state/operation: '${DEPLOY_STATE}'."
    echo "      Note: This curl call only initiates the deployment. It does not poll for completion."
    echo "      If state is 'READY', it's deployed. If it's an operation name, it's processing."
else
    echo "WARNING: Could not determine deployment state from API response. Check Apigee console."
    echo "Response: ${DEPLOY_RESPONSE_JSON}"
fi
echo "INFO: Proxy deployment step finished."

# --- 7. Retrieve Apigee Hostname and Proxy Basepath ---
echo "INFO: Retrieving Apigee hostname..."
APIGEE_HOSTNAME=""

# This approach uses a direct API call to get environment groups.
# It assumes the desired hostname is the first hostname of the first environment group.
# This may not be specific to the $APIGEE_ENV if multiple environment groups exist or if
# $APIGEE_ENV is not attached to the first group.
# The script has already defined $PROJECT_ID and acquired $ACCESS_TOKEN.

echo "INFO: Attempting to retrieve hostname via direct API call to organizations/${PROJECT_ID}/envgroups..."
# Use the ACCESS_TOKEN obtained earlier in the script for authorization
APIGEE_HOSTNAME_JSON_RESPONSE=$(curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -s "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/envgroups")

if [ -n "$APIGEE_HOSTNAME_JSON_RESPONSE" ]; then
    APIGEE_HOSTNAME=$(echo "$APIGEE_HOSTNAME_JSON_RESPONSE" | jq -r ".environmentGroups[0].hostnames[0]")
else
    echo "WARNING: Received no response from the envgroups API."
    APIGEE_HOSTNAME="" # Ensure it's empty
fi

if [ -z "$APIGEE_HOSTNAME" ] || [ "$APIGEE_HOSTNAME" == "null" ]; then # jq might return string "null" if path doesn't yield a value
    echo "WARNING: Could not automatically determine an active hostname using the direct API call method."
    echo "         This could be due to no environment groups, no hostnames configured for the first group,"
    echo "         the API call failing, or the jq path '.environmentGroups[0].hostnames[0]' not finding a value."
    APIGEE_HOSTNAME="YOUR_APIGEE_HOSTNAME_HERE" # Placeholder for manual override if needed
else
    echo "INFO: Retrieved Apigee hostname (from first env group): ${APIGEE_HOSTNAME}"
fi

echo "INFO: Retrieving basepath from proxy definition '${PROXY_ENDPOINT_DEF_FILE}'..."
# Attempt to extract BasePath. Robust parsing requires XML tools, but grep can often work for simple cases.
# This assumes BasePath is like <BasePath>/my/path</BasePath>
PROXY_BASEPATH=$(grep -oPm1 "(?<=<BasePath>)/[^<]+" "${PROXY_ENDPOINT_DEF_FILE}" || echo "/YOUR_PROXY_BASEPATH")
if [[ "${PROXY_BASEPATH}" == "/YOUR_PROXY_BASEPATH" ]]; then
    echo "WARNING: Could not automatically determine proxy basepath. Please check '${PROXY_ENDPOINT_DEF_FILE}'."
fi
echo "INFO: Proxy basepath: ${PROXY_BASEPATH}"

# --- 8. Output Curl Command ---
echo "--------------------------------------------------"
echo "SUCCESS: Deployment completed."
if [[ "${APIGEE_HOSTNAME}" != "YOUR_APIGEE_HOSTNAME_HERE" && "${PROXY_BASEPATH}" != "/YOUR_PROXY_BASEPATH" ]]; then
    echo "INFO: Sample curl command to invoke the proxy:"
    echo "curl https://${APIGEE_HOSTNAME}${PROXY_BASEPATH}"
else
    echo "INFO: Could not determine full invoke URL. Please verify hostname and basepath manually."
fi
echo "--------------------------------------------------"

# --- 9. Optional: Publish a message ---
if [ "${PUBLISH_MESSAGE}" = true ]; then
    echo "INFO: Publishing a sample message to topic '${TOPIC_NAME}' as requested by --publish flag..."
    gcloud pubsub topics publish "${TOPIC_NAME}" \
        --message="Hello from deploy.sh script! Timestamp: $(date)" \
        --project "${PROJECT_ID}"
    echo "INFO: Sample message published."
fi

# --- 10. Cleanup ---
echo "INFO: Cleaning up local proxy bundle '${PROXY_BUNDLE_NAME}'..."
rm -f "${PROXY_BUNDLE_NAME}"
echo "INFO: Cleanup complete."
echo "INFO: Script finished."
