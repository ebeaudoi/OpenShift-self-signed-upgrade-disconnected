### ## 1. Checking Upgrade Status and Path

These commands help you see the cluster's current version and what upgrade paths are available.

* **Check for available updates**
    ```bash
    oc adm upgrade
    ```
    This is the primary command to check the cluster's current version and see if the Cluster Version Operator (CVO) has detected any available updates from its configured source.

* **Get release information**
    ```bash
    oc adm release info
    ```
    This command displays detailed information about the current release version, including its component versions and a link to the release notes.

* **Verify a specific upgrade path**
    ```bash
    oc adm release info ${Next_Version} | grep Upgrades
    ```
    This command checks the metadata for a specific target release (`${Next_Version}`) to see the valid versions it can be upgraded *from*. This is useful for confirming your intended upgrade path is valid.

***

### ## 2. Verifying the Update Service (OSUS)

These commands are for inspecting the components of the OpenShift Update Service (OSUS) in a disconnected environment.

* **Get all resources in the OSUS namespace**
    ```bash
    oc get all -n openshift-update-service
    ```
    This command provides a complete overview of all running pods, services, deployments, and other resources within the `openshift-update-service` namespace, giving you a quick health check of the service.

* **Check OSUS routes**
    ```bash
    oc get routes.route.openshift.io -n openshift-update-service
    ```
    This command checks if the OSUS is exposed via an OpenShift `Route`, which might be used for external access or monitoring.

* **Confirm trusted CA is mounted in the OSUS pod**
    ```bash
    oc get pod -n openshift-update-service update-service-oc-mirror-56f99dff66-267xq -o yaml | grep -B1 "trusted-ca"
    ```
    This command inspects the configuration of a specific OSUS pod to verify that a custom Certificate Authority (CA) has been correctly mounted. This is critical for ensuring OSUS can communicate with a mirror registry that uses a self-signed TLS certificate.

***

### ## 3. Inspecting the Cluster Version Operator (CVO)

The CVO is the core operator responsible for managing upgrades. These commands help you diagnose its status and configuration.

* **List CVO pods**
    ```bash
    oc get pods -n openshift-cluster-version
    ```
    This command lists the pods for the CVO to ensure they are `Running` and healthy.

* **Get CVO pod logs**
    ```bash
    oc logs cluster-version-operator-69dc855c46-xrxxw -n openshift-cluster-version
    ```
    This command retrieves the logs from a specific CVO pod. The CVO logs are the most important place to find detailed error messages about why an upgrade is failing or not appearing.

* **Get the full CVO configuration and status**
    ```bash
    oc get clusterversions.config.openshift.io version -o yaml
    ```
    This command displays the complete YAML definition for the `clusterversion` singleton resource, including its configuration (`spec`) and detailed status (`status`), which contains current version info and any error conditions.

* **Extract the CVO's upstream URL**
    ```bash
    oc get clusterversion version -o jsonpath='{.spec.upstream}'
    ```
    This command uses a JSONPath query to quickly extract only the `upstream` URL. This shows you exactly which update source (either the default Red Hat servers or your internal OSUS) the CVO is configured to check.

* **Display CVO status conditions**
    ```bash
    oc get clusterversion version -o jsonpath='{.status.conditions}' | jq .
    ```
    This command extracts and formats the CVO's `status.conditions`. This is where you'll find high-level errors like `Unable to retrieve available updates` or `currently reconciling cluster version`.

***

### ## 4. Verifying Image Mirroring and Configuration

These commands are used to check that the disconnected image mirroring is configured correctly.

* **Search for a release image in the mirror registry**
    ```bash
    podman search --list-tags [your-mirror-registry.com/openshift-ocp-release](https://your-mirror-registry.com/openshift-ocp-release) | grep "4.16.5"
    ```
    This command is run from a machine with access to your mirror registry to confirm that the target OpenShift release image was successfully mirrored and is available.

* **Check the ImageDigestMirrorSet configuration**
    ```bash
    oc get idms -n openshift-marketplace image-digest-mirror -o yaml
    ```
    This command inspects the `ImageDigestMirrorSet` (IDMS) resources. These objects are responsible for telling the cluster to redirect image pull requests from the public Red Hat registries to your private mirror registry.

***

### ## Node Recovery Command

* **Set Kubeconfig for node recovery**
    ```bash
    export KubeCONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
    ```
    This command is run directly on an OpenShift node, typically a control plane node, for disaster recovery. It sets the `KUBECONFIG` to a local recovery file, allowing you to run `oc` commands to investigate or manage the cluster even if the main API server is unavailable.
````