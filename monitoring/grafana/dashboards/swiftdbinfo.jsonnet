local g = import 'github.com/grafana/grafonnet/gen/grafonnet-v11.0.0/main.libsonnet';

local vars = {
  datasource:
    g.dashboard.variable.datasource.new('datasource', 'pcp-redis-datasource')
    + g.dashboard.variable.datasource.withRegex(".*storage.*"),

  host:
    g.dashboard.variable.query.new('host', "label_values(hostname)")
    + g.dashboard.variable.query.withDatasourceFromVariable(self.datasource)
    + g.dashboard.variable.query.withRefresh('time'),

  instance:
    g.dashboard.variable.query.new('instance', "label_values(swift_db_name)")
    + g.dashboard.variable.query.withDatasourceFromVariable(self.datasource)
    + g.dashboard.variable.query.selectionOptions.withMulti()
    + g.dashboard.variable.query.selectionOptions.withIncludeAll()
    + g.dashboard.variable.query.withRefresh('time'),
};

g.dashboard.new('Swift DB info')
+ g.dashboard.withTags(['swift'])
+ g.dashboard.time.withFrom('now-30m')
+ g.dashboard.time.withTo('now')
+ g.dashboard.withRefresh('10s')
+ g.dashboard.withVariables([vars.datasource, vars.host, vars.instance])
+ g.dashboard.withPanels(
  g.util.grid.makeGrid([
    g.panel.row.new('Swift DB info For $instance')
    + g.panel.row.withPanels([g.panel.timeSeries.new('Number of Objects')
      + g.panel.timeSeries.queryOptions.withTargets([{ expr: 'swiftdbinfo.object.count{hostname == "$host", swift_db_name == "$instance"}', legendFormat: '$instance', format: 'time_series' }])
      + g.panel.timeSeries.queryOptions.withDatasource("pcp-redis-datasource", '$datasource')
      + g.panel.timeSeries.queryOptions.withTransformations([g.panel.timeSeries.queryOptions.transformation.withId("filterFieldsByName")
      +g.panel.timeSeries.queryOptions.transformation.withOptions({
            "include": {
              "pattern": "(time|$instance)"
            }
          })]),

      g.panel.timeSeries.new('Size of DB')
      + g.panel.timeSeries.queryOptions.withTargets([{ expr: 'swiftdbinfo.size{hostname == "$host", swift_db_name == "$instance"}', legendFormat: '$instance', format: 'time_series' }])
      + g.panel.timeSeries.queryOptions.withDatasource("pcp-redis-datasource", '$datasource')
      + g.panel.timeSeries.queryOptions.withTransformations([g.panel.timeSeries.queryOptions.transformation.withId("filterFieldsByName")
      +g.panel.timeSeries.queryOptions.transformation.withOptions({
            "include": {
              "pattern": "(time|$instance)"
            }
          })])
      + g.panel.timeSeries.standardOptions.withMin(0),

      g.panel.timeSeries.new('Distrbution of object sizes in DB')
      + g.panel.timeSeries.queryOptions.withTargets([{ expr: 'swiftdbinfo.object.dist{hostname == "$host", swift_db_name == "$instance"}', legendFormat: '$instance', format: 'time_series' }])
      + g.panel.timeSeries.queryOptions.withTransformations([g.panel.timeSeries.queryOptions.transformation.withId("filterFieldsByName")
        + g.panel.timeSeries.queryOptions.transformation.withOptions({
            "include": {
              "pattern": "(time|$instance)"
            }
          })])
      + g.librarypanel.withType("volkovlabs-echarts-panel")
      + g.panel.timeSeries.queryOptions.withDatasource("pcp-redis-datasource", '$datasource')
      + {"options": {
        "baidu": {
          "callback": "bmapReady",
          "key": ""
        },
        "editor": {
          "format": "auto"
        },
        "editorMode": "code",
        "gaode": {
          "key": "",
          "plugin": "AMap.Scale,AMap.ToolBar"
        },
        "getOption": "// Function to extract counts based on the field index\nfunction getCountsByFieldIndex(jsonData, instanceName) {\n  let counts = [];\n\n  // Trim extra quotes or spaces from instanceName\n  instanceName = instanceName.trim().replace(/^\"|\"$/g, '');\n\n  // Check if jsonData is an array and contains elements\n  if (Array.isArray(jsonData) && jsonData.length > 0) {\n    const firstItem = jsonData[0];\n\n    // Check if  'fields' exist in the first item\n    if (firstItem && firstItem && firstItem.fields) {\n      // Find the field that exactly matches the instanceName\n      const field = firstItem.fields.find(f => f.state.displayName.trim() === instanceName);\n      if (field) {\n\n        // Check if 'data' and 'values' exist in the JSON\n        if (field.values) {\n          // Extract values at the field index\n          const values = field.values.filter(value => value != null);\n          console.log(values.filter(value => value != null))\n          // Iterate through values to get counts\n          values.forEach(valueString => {\n            // Remove quotes and split by comma\n            const pairs = valueString.replace(/\"/g, '').split(', ');\n            // Create a list of counts\n            const countsList = pairs.map(pair => parseInt(pair.split('=')[1], 10));\n            counts.push(countsList);\n          });\n        }\n      } else {\n        console.log(\"Field with the specified instance name not found.\");\n      }\n    } else {\n      console.log(\"Invalid JSON structure.\");\n    }\n  } else {\n    console.log(\"Invalid JSON data format.\");\n  }\n\n  return counts;\n}\n\n// Function to extract keys based on the field index\nfunction getKeysByFieldIndex(jsonData, instanceName) {\n  let keys = [];\n  \n  // Trim extra quotes or spaces from instanceName\n  instanceName = instanceName.trim().replace(/^\"|\"$/g, '');\n\n  // Check if jsonData is an array and contains elements\n  if (Array.isArray(jsonData) && jsonData.length > 0) {\n    const firstItem = jsonData[0];\n\n    // Check if  'fields' exist in the first item\n    if (firstItem && firstItem && firstItem.fields) {\n      // Find the field that exactly matches the instanceName\n      const field = firstItem.fields.find(f => f.state.displayName.trim() === instanceName);\n\n      if (field) {\n\n        // Check if 'data' and 'values' exist in the JSON\n        if (field.values) {\n          // Extract values at the field index\n          const values = field.values.filter(value => value != null);\n\n          // Extract keys from the first string\n          const firstString = values[0].replace(/\"/g, '');\n          keys = firstString.split(', ').map(pair => pair.split('=')[0]);\n        }\n      } else {\n        console.log(\"Field with the specified instance name not found.\");\n      }\n    } else {\n      console.log(\"Invalid JSON structure.\");\n    }\n  } else {\n    console.log(\"Invalid JSON data format.\");\n  }\n\n  return keys;\n}\n\n// Function to convert timestamps to human-readable time\nfunction getReadableTimestamps(jsonData) {\n  let timestamps = [];\n\n  // Check if jsonData is an array and contains elements\n  if (Array.isArray(jsonData) && jsonData.length > 0) {\n    const firstItem = jsonData[0];\n\n    // Check if 'data' and 'values' exist in the JSON\n    if (firstItem && firstItem.fields) {\n      // Extract the timestamps from the first value array\n      const timestampValues = firstItem.fields[0].values;\n\n      // Convert each timestamp to human-readable format\n      timestamps = timestampValues.map(ts => {\n        const date = new Date(ts);\n        return date.toLocaleString(); // Adjust format as needed\n      });\n    } else {\n      console.log(\"Invalid JSON structure.\");\n    }\n  } else {\n    console.log(\"Invalid JSON data format.\");\n  }\n\n  return timestamps;\n}\n\n/**\n * Function to format a 2D array into a list of strings.\n * @param {Array} dataArray - The 2D array to be formatted.\n * @returns {Array} - An array of formatted strings.\n */\nfunction formatArrayToStrings(dataArray) {\n  let formattedStrings = [];\n\n  // Check if dataArray is a 2D array\n  if (Array.isArray(dataArray) && dataArray.length > 0 && Array.isArray(dataArray[0])) {\n    dataArray.forEach((innerArray, i) => {\n      innerArray.forEach((value, j) => {\n        formattedStrings.push([i, j, value]);\n      });\n    });\n  } else {\n    console.log(\"Invalid array format.\");\n  }\n\n  return formattedStrings;\n}\n\n\nconst a = context.panel.data.series;\nconst v = context.grafana.replaceVariables('${instance}');\nconst instanceName = v;\nconsole.log(instanceName);\nconst hours = getReadableTimestamps(a);\nconst days = getKeysByFieldIndex(a, instanceName);\nconst data = formatArrayToStrings(getCountsByFieldIndex(a, instanceName));\noption = {\n  tooltip: {\n    position: 'top'\n  },\n  grid: {\n    height: '80%',\n    top: '0%'\n  },\n  xAxis: {\n    type: 'category',\n    data: hours,\n    splitArea: {\n      show: true\n    }\n  },\n  yAxis: {\n    type: 'category',\n    data: days,\n    splitArea: {\n      show: true\n    }\n  },\n  visualMap: {\n    min: 0,\n    max: 10,\n    calculable: true,\n    orient: 'horizontal',\n    left: 'center',\n    bottom: '0%'\n  },\n  series: [\n    {\n      name: 'Punch Card',\n      type: 'heatmap',\n      data: data,\n      label: {\n        show: true\n      },\n      emphasis: {\n        itemStyle: {\n          shadowBlur: 10,\n          shadowColor: 'rgba(0, 0, 0, 0.5)'\n        }\n      }\n    }\n  ]\n};\nreturn option;",
        "google": {
          "callback": "gmapReady",
          "key": ""
        },
        "map": "none",
        "renderer": "canvas",
        "themeEditor": {
          "config": "{}",
          "name": "default"
        },
        "visualEditor": {
          "code": "return {\n  dataset: context.editor.dataset,\n  series: context.editor.series,\n  xAxis: {\n    type: 'time',\n  },\n  yAxis: {\n    type: 'value',\n    min: 'dataMin',\n  },\n}\n",
          "dataset": [],
          "series": []
        }
      }},

  ])
  + g.panel.row.withRepeat("instance"),

], panelWidth=12)
)
