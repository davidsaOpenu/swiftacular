# Swiftaucular Monitoring

Swiftaucular includes the option to enable monitoring, allowing investigation of performance issues and questions. In this version, we include the option to gather system data during the deployment and, in general, provide performance insights on proxy and storage nodes. This includes metrics such as memory consumption by XFS inodes, object database size, and memory and CPU utilization of the services accessing those databases. All of this is done also with the option for full customization and the ability to add additional metrics that should be collected and custom dashboards.

The monitoring functionality is based on PCP - Performance Co-Pilot, which provides real-time and historical performance data collection, analysis, and visualization capabilities. With PCP, it's possible to gather detailed metrics on system resources, such as CPU, memory, disk I/O, and network usage, along with application-specific data. PCP also includes Redis integration, allowing persistent storage and the ability to replay past data to troubleshoot issues that occurred at specific points in time. In addition, it includes integration with Grafana, introducing customizable dashboards that present the data collected by PCP.


# Setup

The monitoring script uses PCP Ansible, Jsonnet and grafana-client, so follow these steps to set it up:

1. Install the PCP Ansible collection:
    ```bash
    ansible-galaxy collection install performancecopilot.metrics
    ```

2. Install Jsonnet. You can find instructions here: [Jsonnet GitHub Repository](https://github.com/google/jsonnet).

3. If adding new Jsonnet libraries, install `jb` by following the instructions here: [Jsonnet Bundler GitHub Repository](https://github.com/jsonnet-bundler/jsonnet-bundler).

4. Install the Python `grafana-client` package:
    ```bash
    pip install grafana-client
    ```



# Built-in Features

Swiftaucular provides, as part of its setup, a fully working out-of-the-box monitoring tool. The monitoring addition includes a Grafana instance hosted on a dedicated VM created during setup. It also configures the storage and proxy nodes to include persistent storage of the metrics collected using the integrated PCP-Redis option. The Grafana instance is configured with the PCP-Redis datasources for all of the nodes. The pre-created dashboards are also created automatically in the Grafana instance. In this section, we will explain in detail all the existing features.

## Complete Monitoring And Swift Deployment Script

Swiftaucular includes the `run_with_monitor` script, which sets up the monitoring, and runs the deployment and workload tests while recording the monitored metrics.

The script creates all the necessary VMs for the Swift deployment and the monitoring. It then starts the monitoring setup by calling the Ansible playbook `setup-swift-monitoring.yml` to set up the Grafana instance and PCP configuration. The `setup-swift-monitoring.yml` playbook uses PCP-Ansible to install PCP and Grafana ([PCP-Ansible GitHub Repository](https://github.com/performancecopilot/ansible-pcp)).

After the initial setup, the script creates the dashboards by calling a Python script located at `monitoring/grafana/configure_grafana.py`. URLs to the dashboards, containing live versions of the recorded metrics, will be printed out.

When accessing the Grafana instance, a username and password are required. The default is `user: admin`, `password: admin`. On the first access, you will be prompted to change the credentials.

Immediately after the creation of the dashboards, the deployment phase will start. At the end of the deployment, URLs to the dashboards containing the exact time frame of the deployment will be outputted, allowing for investigation of the results at a later time. The same process will occur for the workload tests.

**Example Output:**



## swiftdbinfo PMDA

In addition to collecting metrics on system resources, PCP allows the collection of application-specific data by implementing custom metric collectors called PMDAs. To gather metrics related to the databases Swift uses for storage, we have implemented a PMDA called `swiftdbinfo`.

The implementation of the `swiftdbinfo` PMDA is included in the `monitoring/pmdas/swiftdbinfo` directory. This PMDA adds three additional metrics for each database in the storage nodes. Each of these metrics is associated with the instance domain, resulting in results for each database for each metric. The metrics are:

- `swiftdbinfo.size`
- `swiftdbinfo.object.count`
- `swiftdbinfo.object.dist` (object distribution)

The `swiftdbinfo` PMDA updates the list of instances (databases) it tracks by implementing the `fetch` function. When this function is called by PCP, a `find` command is executed to locate all databases in the file system. The PMDA filters out only the Swift databases and queries them to extract the container, and account. The instance name representing the database is in the following format: `{discovery_time}__{container}__{account}`. The discovery time is added to the instance name to facilitate easy sorting of the instances.

By default, `swiftdbinfo` does not track Swift expired objects databases. This can be easily changed by modifying the PMDA configuration located at the beginning of `monitoring/pmdas/swiftdbinfo/pmdaswiftdbinfo.py` under `Configuration`. To enable tracking of expired objects, set `SHOULD_TRACK_EXPIRING_OBJECTS = True`.

`swiftdbinfo` also adds a label named `swift_db_name` to each database instance, which is implemented in the `simple_label_callback` function. The value of this label is the instance name. This label is useful for easily retrieving the list of instance names from Grafana using built-in functions available for dashboard variables of type Query. In our case, the `label_values()` function called with `label_values(swift_db_name)` is used in the dashboard variables. For a full list of possible query functions supported by PCP Grafana, view: [PCP Grafana Query Functions](https://grafana-pcp.readthedocs.io/en/latest/datasources/redis.html#query-functions).

The `swiftdbinfo.object.dist` metric returns the distribution of sizes of objects in the database by returning the number of objects in each size category. The size categories/buckets can be configured in the configuration section of `monitoring/pmdas/swiftdbinfo/pmdaswiftdbinfo.py`. The default buckets are:

- 0-1 KB
- 1-10 KB
- 10-100 KB
- 100 KB - 1 MB
- 1 MB - 10 MB
- 10 MB - 25 MB
- 25 MB - 50 MB
- 50 MB - 100 MB
- 100 MB - 500 MB
- 500 MB - 1 GB
- 1 GB - 5 GB (5 GB is Swift maximum)

The number and sizes of the buckets can be adjusted depending on the use case. The `swiftdbinfo.object.dist` metric returns the distribution as a string formatted as `bucket=number` separated by commas. This requires further parsing in the dashboard to represent the data, which is returned due to PCP data structure as specified in [PCP Writing PMDA](https://pcp.readthedocs.io/en/latest/PG/WritingPMDA.html#n-dimensional-data).

The `swiftdbinfo` PMDA can be queried directly by running on the relevant storage node:

```bash
pminfo -f swiftdbinfo
```

The `swiftdbinfo` logs appear in `/var/log/pcp/pmcd/swiftdbinfo.log`.

### Configuration

As specified in the previous section, the `swiftdbinfo` PMDA supports configuration of:

- The number and size of buckets used in `swiftdbinfo.object.dist`
- The option to enable tracking of expired objects databases

These configurations can be modified by changing constants in `monitoring/pmdas/swiftdbinfo/pmdaswiftdbinfo.py` in the `Configuration` comment section.




## Built-in Dashboards

As part of the monitoring process, two dashboards are added to the Grafana instance. The dashboards are configured using the `configure_grafana.py` Python script. These dashboards are written in Jsonnet using Grafonnet. The dashboards can be found in `monitoring/grafana/dashboards`. The `configure_grafana.py` script generates the JSON from the Jsonnet dashboards and adds them to the Grafana instance.

### Host Overview

The Host Overview dashboard contains common metrics included in PCP, such as memory and CPU utilization. This dashboard is based on the PCP host overview dashboard, which can be found in the PCP Grafana repository at [PCP Redis Host Overview](https://github.com/performancecopilot/grafana-pcp/blob/77809e9996767d0bdc4b88be58ddbf0f273b981d/src/datasources/redis/dashboards/pcp-redis-host-overview.jsonnet). This dashboard uses an older version of Grafonnet, which is now deprecated. The graph panels it includes are of the graph panel type instead of the time series panel type, which will not be supported in future versions of Grafana. Once PCP creators update to the newer version of Grafonnet and update the dashboard, it should be updated accordingly. Additionally, the dashboard contains metrics related to XFS, such as memory consumption by XFS inodes.

### Swiftdbinfo

The Swiftdbinfo dashboard contains information gathered by the `swiftdbinfo` PMDA. The dashboard variables include options to choose the datasource from the list of storage nodes. It also allows selecting the DB instances to display. Each DB instance will have a row in the dashboard containing all the metrics for that DB. An "All" option is included, which displays metrics for all DBs.

This dashboard is written with the new updated, auto-generated version of Grafonnet. Each row contains three graphs: object count and DB size panels are regular time series panels, while the object size distribution is presented using a Business Charts panel. This panel is part of the Grafana Business Charts plugin, which is installed as part of the monitoring setup. The panel is formatted as a heat map and includes JavaScript code to prepare the data for the selected visualization. This approach is crucial for PCP's complex metrics that require additional processing before being presented, such as separation into fields for n-dimensional data. Built-in Grafana transformations were insufficient, so the echart approach was taken for full customizability.

All panels for the metrics also include Grafana transformations that filter and show only the instance of the specific row. This is implemented with Grafana transformations because querying PCP for a specific label returns results for all instances. Therefore, filtering is done at the Grafana level.


# Dashboard Customization

A nice feature of the system is the ability to customize the dashboards. It's possible to customize the existing dashboards or add new ones.

## Writing a Dashboard Jsonnet

Dashboards should be implemented with Jsonnet. They are generated by the `configure_grafana` script and uploaded to Grafana. To add a new dashboard, place it in the `monitoring/grafana/dashboards` directory. It is recommended to use the newest version of Grafonnet to write the dashboard, similar to what is seen in the `swiftdbinfo` PMDA dashboard. For official documentation, visit [Grafonnet Documentation](https://grafana.github.io/grafonnet/index.html).

If additional Jsonnet libraries are needed, they can be added by running the following command in the root of the project:

```bash
jb install LIBRARY
```

To generate the JSON without uploading it to Grafana, use:

```bash
jsonnet -J vendor monitoring/grafana/dashboards/dashboard.jsonnet
```

Custom dashboards can include additional metrics that are collected by PCP but not presented in the dashboards included in the project. To find all available PCP metrics with the current installation, refer to the [PCP Metrics List](https://pcp.readthedocs.io/en/latest/QG/ListAvailableMetrics.html).

## Steps to Include a Dashboard in Deployment

To include the dashboard in the `run_with_monitor` script so it is deployed and added to the complete setup, add an additional line to the dashboards section in the `run_with_monitor` script:


```bash
declare -A dashboards
dashboards["swiftdbinfo.jsonnet"]="swiftdbinfo"
dashboards["pcp-redis-host-overview.jsonnet"]="pcp-host"
ADD HERE (format is: dashboards[file name relative to monitoring/grafana/dashboards dir]=UID of dashobard)
```

The configuration includes specifying the UID of the dashboard. The UID of the dashboard will be part of the URI, allowing easy access by URL. The full URL of the dashboard will be outputted as part of the script, as explained in previous sections.

## Business Charts

When implementing custom dashboards, it may be a good option to use the Business Charts plugin. This plugin contains multiple options for additional visualizations and the ability to format the data with code, which can be very handy when implementing custom PMDAs with data that needs to be parsed before visualization.

- [Link to all visualizations](https://echarts.apache.org/examples/en/index.html#chart-type-line)
- [Link to plugin docs](https://volkovlabs.io/plugins/business-charts/)



# Adding Additional Metrics

Additional metrics that are collected can be added. PCP gathers metrics through a component named PMDA. It supports the implementation of custom PMDAs. Before adding new PMDAs, it's a good idea to browse and search for existing PMDAs that can be added to the PCP setup. However, if a specific application agent is needed or if an existing agent and PMDA cannot be found, a custom PMDA can be implemented and easily integrated.

## Implementing a PMDA

Before implementing a PMDA, it's recommended to review the documentation regarding the `swiftdbinfo` PMDA, which is also a custom PMDA and can serve as an example for custom PMDAs written in Python. Additionally, there are a couple of very useful resources to review when implementing a new PMDA:

- Blog post on a simple Python PMDA: [Writing a PMDA for PCP](https://ryandoyle.net/posts/writing-a-pmda-for-pcp/)
- Official programmer's guide: [Writing PMDA](https://pcp.readthedocs.io/en/latest/PG/WritingPMDA.html)
- Official Python PMDA example: [PMDA Simple](https://github.com/performancecopilot/pcp/blob/main/src/pmdas/simple/pmdasimple.python)
- Directory with all built-in implemented PMDAs: [Built-in PMDAs](https://github.com/performancecopilot/pcp/tree/main/src/pmdas)

When adding a new PMDA, it's recommended to add it to the `monitoring/pdmas` directory. A directory should be created for each PMDA. This directory should include the PMDA and the install script as described in the above resources.

## Adding PDMA to the Deployment

Once a new PMDA is implemented, it's easy to include it as part of the system. All that needs to be done is add an additional step to the `setup-swift-monitoring.yml` playbook.



```yaml
- name: Setup PDMA_NAME pmda on storage hosts
  hosts: storage
  tasks:
    - name: Copy pdma to host
      copy:
        src: monitoring/pdmas/PDMA_NAME/
        dest: /var/lib/pcp/pmdas/PDMA_NAME/
        mode: u=rwx,g=rwx,o=rwx
    - name: change ownership pf pdma
      command: sudo chown $USER /var/lib/pcp/pmdas/PDMA_NAME
    - name: Install PDMA
      shell: |
            cd /var/lib/pcp/pmdas/PDMA_NAME
            sudo ./Install
    - name: Enable and configure perssitant logging for custom pdma
      shell: |
            sudo sed -i '/\[access\]/i\
            log mandatory on every INTERVAL seconds {\
            METRIC1_NAME\
            METRIC2_NAME\
            METRIC3_NAME\
            }

            ' /var/lib/pcp/config/pmlogger/config.default
```

Add this step after the "Setup swiftdbinfo PMDA on storage hosts" step. When adding the step, change all occurrences of `PDMA_NAME` to the name of the PMDA.

The last sub-step, "Enable and configure persistent logging for custom PMDA," controls the frequency with which metrics are fetched and saved in Redis. All metrics intended for historical queries should be updated in the `pmlogger` config. In the step example, change `INTERVAL` to the desired logging interval and `METRICX_NAME` to include the names of all metrics. For more information on the config structure, view [this guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/global_file_system_2/s1-loggingperformance#s1-loggingperformance).
