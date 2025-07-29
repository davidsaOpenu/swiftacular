from cpmapi import PM_TYPE_U64, PM_SEM_INSTANT, PM_TYPE_STRING, PM_SEM_DISCRETE
import cpmapi
from pcp.pmapi import pmUnits
from typing import Dict, Optional
from pcp.pmda import PMDA, pmdaMetric, pmdaInstid, pmdaIndom
import subprocess
from swift.container.backend import ContainerBroker
import sqlite3
import json
from datetime import datetime, timezone
from dataclasses import dataclass
# Configuration

SHOULD_TRACK_EXPIRING_OBJECTS = False
EXPIRING_OBJECTS_ACCOUNT_INDICATOR = "expiring"
BUCKET_DICT = {
    '0-1 KB': 1024,
    '0-10 KB': 10240,
    '10-100 KB': 102400,
    '100 KB - 1 MB': 1048576,
    '1 MB - 10 MB': 10485760,
    '10 MB - 25 MB': 26214400,
    '25 MB - 50 MB': 52428800,
    '50 MB - 100 MB': 104857600,
    '100 MB - 500 MB': 524288000,
    '500 MB - 1 GB': 1073741824,
    '1 GB - 5 GB': 5368709120
}

# Configuration End

SWIFT_DB_PATH_INDICATOR = "containers"

@dataclass
class DB:
    path: str
    container: str
    account: str
    discovery_time: int
    id: Optional[int] = None

    def __str__(self):
        return f"{str(self.discovery_time)}__{self.container}__{self.account}"


OBJECT_COUNT_QUERY = """SELECT COUNT(*) AS TotalNumberOfObjects
FROM object;"""

kbyteUnits = pmUnits(1, 0, 0, cpmapi.PM_SPACE_KBYTE, 0, 0)
countUnits = pmUnits(0, 0, 1, 0, 0, cpmapi.PM_COUNT_ONE)
zeroUnits = pmUnits(0, 0, 0, 0, 0, 0)

class EtcdPMDA(PMDA):

    def __init__(self, name: str, domain: int):
        super().__init__(name, domain)

        self.id_to_db = {}
        self.db_hashes = {}
        self.db_instances = []
        self.db_instances_indom = self.indom(0)
        self.next_id = 0
        self.__add_dbs()
        self.add_indom(pmdaIndom(self.db_instances_indom, [pmdaInstid(id, db) for id, db in self.db_instances]))
        self.set_fetch(self.simple_fetch)
        self.set_fetch_callback(self.fetch_callback)
        self.set_label_callback(self.simple_label_callback)
        self.add_metric(name + '.size', pmdaMetric(
            PMDA.pmid(0, 0),
            PM_TYPE_U64,
            self.db_instances_indom,
            PM_SEM_INSTANT,
            kbyteUnits
        ))
        self.add_metric(name + '.object.count', pmdaMetric(
            PMDA.pmid(0, 1),
            PM_TYPE_U64,
            self.db_instances_indom,
            PM_SEM_INSTANT,
            countUnits
        ))
        self.add_metric(name + '.object.dist', pmdaMetric(
            PMDA.pmid(0, 2),
            PM_TYPE_STRING,
            self.db_instances_indom,
            PM_SEM_DISCRETE,
            zeroUnits
        ))
        self.metric_to_callbacks = [self.__get_db_size, self.__get_object_count, self.__get_object_distrubution]


    def __find_dbs(self):
        command = [
            'find', '/srv', '-type', 'f',
            '(', '-name', '*.sqlite', '-o', '-name', '*.db', '-o', '-name', '*.sqlite3', ')'
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            self.log(f"Error: {stderr}")
        return stdout.splitlines()

    def __add_dbs(self):
        try:
            for db_path in self.__find_dbs():
                if SWIFT_DB_PATH_INDICATOR in db_path:
                    db_info = ContainerBroker(db_path).get_info()
                    db = DB(path=db_path,container=db_info["container"], account=db_info["account"],
                             discovery_time=int(datetime.now(timezone.utc).timestamp()))
                    is_expired_objects = EXPIRING_OBJECTS_ACCOUNT_INDICATOR in db.account
                    if self.db_hashes.get(db.path) is None and (not is_expired_objects or SHOULD_TRACK_EXPIRING_OBJECTS):
                        self.db_hashes[db.path] = True
                        db.id = self.next_id
                        self.id_to_db[self.next_id] = db
                        self.db_instances.append((int(self.next_id), str(db)))
                        self.next_id += 1
        except Exception as e:
            self.log(f"exception occured when detecting new dbs Error: {str(e)}")


    def simple_label_callback(self, indom, inst: int):
        '''
        Return JSONB format labelset for an inst in given indom, as a string
        '''
        if indom == self.db_instances_indom and inst in self.id_to_db.keys():
            db = self.id_to_db[inst]
            return json.dumps({"swift_db_name":str(db)})
        return json.dumps({})

    def simple_fetch(self):
        self.__add_dbs()
        self.clear_indoms()
        self.add_indom(pmdaIndom(self.db_instances_indom, [pmdaInstid(id, db) for id, db in self.db_instances]))
        #self.replace_indom(self.db_instances_indom, [pmdaInstid(id, db) for id, db in self.db_instances])

    def __get_db_size(self, db: DB):
        info = ContainerBroker(db.path).get_info()
        return [info["bytes_used"], 1]

    def __query(self, path, query):
        conn = sqlite3.connect(path, check_same_thread=False)
        res = conn.execute(query)
        rows = res.fetchall()
        conn.close()
        return rows


    def __get_object_distrubution(self, db: DB):
        self.log(f"executing object distubution query for: {str(db)} stored at {db.path}")
        result = self.__query(db.path, generate_named_bucket_query(BUCKET_DICT))
        completeResult = {k: 0 for k, _ in BUCKET_DICT.items()}
        for row in result:
            completeResult[row[0]] = row[1]
        return [", ".join(map(lambda a: f"{a[0]}={a[1]}", completeResult.items())), 1]

    def __get_object_count(self, db: DB):
        self.log(f"executing count query for: {str(db)} stored at {db.path}")
        result = self.__query(db.path, OBJECT_COUNT_QUERY)
        return [result[0][0], 1]

    # item is id of metric is this pdma as set in add metric fucntion
    def fetch_callback(self, cluster, item: int, inst: int):
        self.log(f" number is {inst}")
        if inst >= self.next_id:
            return [cpmapi.PM_ERR_INST, 0]

        self.log(f"fetching: cluster: {cluster} item: {item} instance: {inst}")
        if item >= len(self.metric_to_callbacks):
            return [0, 0]
        try:
            callback = self.metric_to_callbacks[item]
            db = self.id_to_db[inst]
            return callback(db)
        except Exception as e:
            self.log(str(e))
            return [0, 0]


def generate_named_bucket_query(bucket_dict: Dict[str,int]):
    """
    Generate an SQL query to count the number of objects in each named bucket range.

    Parameters:
    - bucket_dict (dict): Dictionary where the key is the bucket name and the value is the upper bound of the bucket range.

    Returns:
    - str: The SQL query string.
    """
    # Initialize the start size for the first bucket
    start = 0

    # Create CASE statements and ORDER BY statements
    case_statements = []
    order_statements = []

    # Iterate through the dictionary to create CASE statements
    for i, (name, upper_bound) in enumerate(bucket_dict.items()):
        # Handle the bucket range with the previous start and the current upper bound
        case_statements.append(f"WHEN size BETWEEN {start} AND {upper_bound} THEN '{name}'")
        order_statements.append(f"WHEN Bucket = '{name}' THEN {i + 1}")
        # Update start for the next bucket range
        start = upper_bound + 1

    # Add an 'else' case for any sizes larger than the largest bucket
    case_statements.append(f"ELSE 'Above {upper_bound}'")

    # Join CASE statements to form the complete CASE block
    case_block = "CASE " + " ".join(case_statements) + " END"

    # Generate the complete SQL query
    query = f"""
SELECT
    {case_block} AS Bucket,
    COUNT(*) AS NumberOfObjects
FROM object
GROUP BY Bucket
ORDER BY
    CASE { ' '.join(order_statements) } ELSE {len(bucket_dict) + 1} END;
"""
    return query


if __name__ == '__main__':
    EtcdPMDA('swiftdbinfo', 400).run()
