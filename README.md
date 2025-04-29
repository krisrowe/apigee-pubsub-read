# Apigee Pub/Sub Proxy Deployment Script

This script automates the deployment of an Apigee API proxy designed to interact with Google Cloud Pub/Sub. It handles the creation of necessary GCP resources, zipping the proxy bundle, deploying it to a specified Apigee environment, and providing a sample `curl` command for invocation.

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

1.  **Google Cloud SDK (`gcloud`)**: Ensure `gcloud` is installed and authenticated with appropriate permissions.
    * Installation: [Google Cloud SDK Documentation](https://cloud.google.com/sdk/docs/install)
2.  **`jq`**: A lightweight and flexible command-line JSON processor.
    * Installation: [jq Official Website](https://stedolan.github.io/jq/download/)
    * Example: `sudo apt-get install jq` (Debian/Ubuntu), `brew install jq` (macOS)
3.  **`zip` utility**: Commonly pre-installed on most Linux and macOS systems.
4.  **Project Structure**: The script expects the following directory structure from the root of this repository (`apigee-pub-sub`):
    ```
    apigee-pub-sub/
    ├── apigee/
    │   └── apiproxy/  # Contains your Apigee proxy source files
    │       ├── proxies/
    │       │   └── default.xml  # Expected to contain <BasePath>
    │       ├── policies/
    │       ├── targets/
    │       └── ... (other proxy files)
    └── util.sh
    └── README.md
    ```
5.  **IAM Permissions**: The user or service account executing `util.sh` needs sufficient permissions in your GCP project (`$PROJECT_ID`) to:
    * Manage Apigee resources (import/deploy proxies, read environment/envgroup details). Roles like `roles/apigee.admin` are comprehensive.
    * Manage Pub/Sub resources (create topics/subscriptions, set IAM policies). Roles like `roles/pubsub.admin` work.
    * Manage IAM Service Accounts (create service accounts, set IAM policies). Roles like `roles/iam.serviceAccountAdmin` and `roles/resourcemanager.projectIamAdmin` (or more granular permissions) are needed.

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

* `PROXY_NAME`: The name assigned to the API proxy in Apigee (default: `"apigee-pub-sub-proxy"`).
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
    * The script relies on the Apigee environment being attached to an Environment Group with a configured hostname. If the hostname cannot be found, a placeholder will be used in the output.
    * Basepath retrieval uses `grep` on `apigee/apiproxy/proxies/default.xml`. If your basepath is defined elsewhere or the file doesn't exist, it will output a placeholder.
* **Proxy Import/Deploy Fails**: Check the `gcloud` output for specific error messages from Apigee. This could be due to issues in the proxy bundle itself.
