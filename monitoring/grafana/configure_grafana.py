import argparse
import json
import os
import subprocess
from grafana_client import GrafanaApi

# Initialize the Grafana API client
def initialize_client(endpoint, user, password):
    return GrafanaApi(auth=(user, password), host=endpoint)

# Create PCP datasource
def create_pcp_datasource(client: GrafanaApi, name: str, ip: str):
    datasource_config = {
        "name": name,
        "type": "pcp-redis-datasource",
        "url": f"http://{ip}:44322",
        "access": "proxy",
        "basicAuth": False,
        "isDefault": False,
        "editable": True
    }
    try:
        # Check if datasource already exists
        existing_datasources = client.datasource.list_datasources()
        for ds in existing_datasources:
            if ds.get('name') == name:
                print(f"Datasource '{name}' already exists, updating instead...")
                # Update existing datasource
                client.datasource.update_datasource_by_uid(ds['uid'], datasource_config)
                print("Datasource updated successfully")
                return

        # Create new datasource if it doesn't exist
        client.datasource.create_datasource(datasource_config)
        print("Datasource created successfully")
    except Exception as e:
        print(f"Failed to create/update datasource: {e}")
        raise(e)

# Delete default PCP datasource
def delete_default_pcp_datasource(client: GrafanaApi):
    try:
        client.datasource.delete_datasource_by_name("PCP Redis")
        print("Default PCP datasource deleted successfully")
        return
    except Exception as e:
        print(f"Failed to delete default PCP datasource: {e}")

# TODO: Quick and dirty. Proper solution put jsonnet on graphana VM
def find_jsonnet():
    home = os.path.expanduser('~')
    search_paths = [
        os.path.join(home, '.local', 'bin', 'jsonnet'),
    ]

    for path in search_paths:
        if os.path.exists(path) and os.path.isfile(path):
            return path
    return None

def run_jsonnet_with_imports(jsonnet_file: str):
    """
    Run jsonnet using shutil.which to find the executable.
    """
    jsonnet_path = find_jsonnet()

    if not jsonnet_path:
        print("Jsonnet executable not found. Ensure it's installed and in your PATH.")
        return None

    try:
        result = subprocess.run(
            [jsonnet_path, "-J", "vendor", jsonnet_file],
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            return result.stdout
        else:
            print(f"Error: {result.stderr}")
            return None

    except Exception as e:
        print(f"Error running jsonnet: {e}")
        return None

# Create dashboard
def create_dashboard(client: GrafanaApi, dashboard_json, uid: str):
    dashboard_json["uid"] = uid
    try:
        response = client.dashboard.update_dashboard({
            "dashboard": dashboard_json,
            "overwrite": True
        })
    except Exception as e:
        print(f"Failed to create dashboard: {e}")

# Main function to parse arguments and call the appropriate functions
def main():
    parser = argparse.ArgumentParser(description="Grafana PCP Datasource and Dashboard Manager")

    subparsers = parser.add_subparsers(dest="command")

    # Subparser for creating PCP datasource
    create_ds_parser = subparsers.add_parser("create-pcp-datasource", help="Create a PCP datasource")
    create_ds_parser.add_argument("endpoint", help="Grafana endpoint")
    create_ds_parser.add_argument("user", help="Grafana username")
    create_ds_parser.add_argument("password", help="Grafana password")
    create_ds_parser.add_argument("name", help="Datasource name")
    create_ds_parser.add_argument("ip", help="IP address of the datasource")

    # Subparser for deleting default PCP datasource
    delete_ds_parser = subparsers.add_parser("delete-default-pcp-datasource", help="Delete the default PCP datasource")
    delete_ds_parser.add_argument("endpoint", help="Grafana endpoint")
    delete_ds_parser.add_argument("user", help="Grafana username")
    delete_ds_parser.add_argument("password", help="Grafana password")

    # Subparser for creating dashboard
    create_dash_parser = subparsers.add_parser("create-dashboard", help="Create a Grafana dashboard")
    create_dash_parser.add_argument("endpoint", help="Grafana endpoint")
    create_dash_parser.add_argument("user", help="Grafana username")
    create_dash_parser.add_argument("password", help="Grafana password")
    create_dash_parser.add_argument("json_file_path", help="Path to the dashboard JSON file")
    create_dash_parser.add_argument("uid", help="Dashboard requested UID")

    args = parser.parse_args()

    client = initialize_client(args.endpoint, args.user, args.password)

    if args.command == "create-pcp-datasource":
        create_pcp_datasource(client, args.name, args.ip)
    elif args.command == "delete-default-pcp-datasource":
        delete_default_pcp_datasource(client)
    elif args.command == "create-dashboard":
        dashboard_json = json.loads(run_jsonnet_with_imports(args.json_file_path))
        if dashboard_json:
            create_dashboard(client, dashboard_json, args.uid)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
