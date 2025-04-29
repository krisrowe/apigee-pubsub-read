# Apigee Reading Messages from Cloud Pub/Sub 

This script provides a 100% repeatable automation of the full deployment of a working integration between an Apigee API proxy and a Google Cloud Pub/Sub topic, where a client application is able to make an API call and retrieve the next available message. It handles the creation of all necessary GCP resources for both Apigee and Cloud Pub/Sub, including configuration of a service account with permissions. It even concludes by providing the sample `curl` command for invocation.

This script can be safely run repeatedly to ensure all components are deployed and configured. This script does NOT provision Apigee in the GCP project specified, so that must be done in advance.

## Features

* **Environment Variable Checks**: Ensures `PROJECT_ID` and `APIGEE_ENV` are set.
* **Prerequisite Tool Checks**: Verifies the presence of `gcloud` and `jq`.
* **Idempotent Resource Creation**:
    * Creates a Google Cloud Service Account (`swim-reader` by default) if it doesn't exist.
    * Creates a Google Cloud Pub/Sub Topic (`swim-incoming` by default) if it doesn't exist.
    * Creates a Google Cloud Pub/Sub Subscription (`swim-api-sub` by default) for the topic if it doesn't exist.
* **IAM Permissions**: Grants the service account necessary permissions (`roles/pubsub.consumer`, `roles/pubsub.viewer`) on the created Pub/Sub subscription.
* **Proxy Bundling**: Zips the Apigee proxy code from the local `apigee/apiproxy` directory.
* **Apigee Deployment**:
    * Imports the proxy bundle into Apigee, creating a new revision.
    * Deploys the new revision to the specified Apigee environment.
    * Assigns the created service account as the runtime service account for the deployed proxy revision.
* **Endpoint Retrieval**: Attempts to retrieve the Apigee environment hostname and the proxy's basepath to construct a sample invocation URL.
* **Test Message Publishing**: An optional `--publish` flag allows publishing a sample message to the Pub/Sub topic after successful deployment.
* **Cleanup**: Removes the locally created proxy zip bundle after deployment.

## Prerequisites

1.  **Google Cloud SDK (`gcloud`)**: Ensure `gcloud` is installed and authenticated. The script uses `gcloud` to:
    * Obtain an access token for API calls (`gcloud auth print-access-token`).
    * Manage Pub/Sub resources (topics, subscriptions).
    * Manage IAM Service Accounts.
    * (Optionally) Publish a test message to Pub/Sub.
    * Installation: [Google Cloud SDK Documentation](https://cloud.google.com/sdk/docs/install)
2. **Apigee X or Hybrid Organization Provisioned**: This script assumes that an Apigee organization (X or Hybrid) is already provisioned in your Google Cloud Project. The script will deploy a proxy to an existing Apigee environment within this organization.
    * If you need to set up a new Apigee evaluation organization, you can follow the steps in the [Apigee evaluation provisioning wizard documentation](https://cloud.google.com/apigee/docs/api-platform/get-started/eval-orgs).
3.  **`jq`**: A lightweight and flexible command-line JSON processor.
    * Installation: [jq Official Website](https://stedolan.github.io/jq/download/)
    * Example: `sudo apt-get install jq` (Debian/Ubuntu), `brew install jq` (macOS)
4.  **`zip` utility**: Commonly pre-installed on most Linux and macOS systems.
5.  **IAM Permissions**: The user or service account executing `util.sh` (or the identity used by `gcloud auth print-access-token`) needs sufficient permissions in your GCP project (`$PROJECT_ID`) to:
    * **Apigee**:
        * Import and deploy proxies (e.g., `apigee.developerAdmin`, `apigee.deployer`, or `apigee.admin` for broader access; or granular permissions like `apigee.apis.create`, `apigee.apis.delete`, `apigee.apirevisions.deploy`, `apigee.environments.getDeployments`).
        * List environment groups and their details to determine hostnames (e.g., `apigee.envgroups.list`, `apigee.envgroups.get` or included in `apigee.reader` / `apigee.admin`).
    * **Pub/Sub**:
        * Create and manage topics and subscriptions (e.g., `roles/pubsub.editor` or `roles/pubsub.admin`).
        * Set IAM policies on subscriptions (included in `roles/pubsub.admin` or via `resourcemanager.projects.setIamPolicy` if setting at project level and filtering down, though the script targets subscription-level binding).
        * The service account created by the script (`swim-reader`) will be granted `roles/pubsub.subscriber` on the subscription.
    * **IAM Service Accounts**:
        * Create service accounts and set IAM policies (e.g., `roles/iam.serviceAccountAdmin` for creating SAs, and `roles/resourcemanager.projectIamAdmin` or appropriate permissions for binding IAM policies for Pub/Sub access).
    * **Service Control / Service Usage** (Implicit):
        * Ensure the Apigee API (`apigee.googleapis.com`) and Pub/Sub API (`pubsub.googleapis.com`) are enabled for the project.

## Environment Variables

Before running the script, you must set the following environment variables:

* `PROJECT_ID`: Your Google Cloud Project ID where Apigee and Pub/Sub resources reside.
    ```bash
    export PROJECT_ID="your-gcp-project-id"
    ```
* `APIGEE_ENV`: The target Apigee environment name where the proxy will be deployed.
    ```bash
    export APIGEE_ENV="your-apigee-environment-name"
    # Example: export APIGEE_ENV="eval"
    ```

## Usage

1.  **Clone the repository** (if you haven't already).
2.  **Navigate to the root directory**:
    ```bash
    cd apigee-pub-sub
    ```
3.  **Make the script executable**:
    ```bash
    chmod +x util.sh
    ```
4.  **Set the required environment variables** (as described above).
5.  **Run the script**:

    * To deploy the proxy:
        ```bash
        ./util.sh
        ```
    * To deploy the proxy and then publish a sample message to the `swim-incoming` topic:
        ```bash
        ./util.sh --publish
        ```

The script will output progress information and, upon successful completion, a sample `curl` command to invoke your deployed API proxy.

## Script Configuration

The following variables are defined at the beginning of `util.sh` and can be modified if your naming conventions or proxy structure differ:

* `PROXY_NAME`: The name assigned to the API proxy in Apigee (default: `"messages"`).
* `PROXY_MAIN_DIR`: The top-level directory containing the `apiproxy` folder (default: `"apigee"`).
* `PROXY_SOURCE_SUBDIR`: The name of the directory containing the proxy bundle files (default: `"apiproxy"`).
* `SERVICE_ACCOUNT_NAME`: The name for the Google Cloud Service Account (default: `"swim-reader"`).
* `TOPIC_NAME`: The name for the Google Cloud Pub/Sub topic (default: `"swim-incoming"`).
* `SUBSCRIPTION_NAME`: The name for the Google Cloud Pub/Sub subscription (default: `"swim-api-sub"`).
* `PROXY_ENDPOINT_DEF_FILE`: Path to the XML file (relative to the script's execution directory) expected to contain the `<BasePath>` definition for your proxy (default: `"${PROXY_MAIN_DIR}/${PROXY_SOURCE_SUBDIR}/proxies/default.xml"`).

## Troubleshooting

* **Permission Errors**: Most issues are related to insufficient IAM permissions for the `gcloud` user/SA running the script. Review the "IAM Permissions" section.
* **`jq` not found**: Ensure `jq` is installed and in your system's PATH.
* **Hostname/Basepath Retrieval Issues**:
    * The script attempts to retrieve a hostname by fetching all environment groups via the Apigee API and using the first hostname of the first listed group. If this hostname is not the correct one for your target environment (`$APIGEE_ENV`), or if the API call fails (e.g., due to permissions or network issues), or if no hostnames are configured, a placeholder will be used. You might need to manually identify the correct hostname.
    * Basepath retrieval uses `grep` on the `proxies/default.xml` file within your proxy bundle structure. If your basepath is defined elsewhere or the file doesn't exist as expected, it will output a placeholder.
* **Proxy Import/Deploy Fails**:
    * Check the script's output for error messages from `curl` or the JSON response from the Apigee API. This could be due to:
        * Issues with the access token (expired, insufficient scopes).
        * Problems with the proxy bundle itself (validation errors not caught by `validate=false`).
        * The service account specified for deployment lacking permissions or not existing.
        * Network connectivity to `apigee.googleapis.com`.
    * The script prints the HTTP status code and the full API response body for the import step, which should help diagnose issues.

## Other Notes

* **Project Structure**: The script expects the following directory structure from the root of this repository (where `util.sh` is located):
    ```
    ./                          # Your project root (e.g., apigee-pubsub-read/)
    +-- apigee/
    |   +-- messages/
    |       +-- apiproxy/       # Contains your Apigee proxy source files
    |           +-- proxies/
    |           |   +-- default.xml   # Expected to contain <BasePath>
    |           +-- policies/
    |           +-- targets/
    |           +-- messages.xml    # Your main proxy XML (e.g., messages.xml)
    +-- util.sh
    +-- README.md
    ```