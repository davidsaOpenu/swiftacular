local grafana = import 'github.com/grafana/grafonnet-lib/grafonnet/grafana.libsonnet';

grafana.dashboard.new(
  'Host Overview',
  tags=['swift'],
  time_from='now-30m',
  time_to='now',
  refresh='10s',
)
.addTemplate(
  grafana.template.datasource(
    'datasource',
    'pcp-redis-datasource',
    'PCP Redis',
  )
)
.addTemplate(
  grafana.template.new(
    'host',
    '$datasource',
    'label_values(hostname)',
    refresh='load',
  )
)
.addTemplate(
  grafana.template.new(
    'instance',
    '$datasource',
    'label_values(swift_db_name)',
    refresh='load',
    sort=1,
  )
)

.addPanel(
  grafana.row.new(
    title='Overview'
  ), gridPos={
    x: 0,
    y: 0,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Load average',
    datasource='$datasource',
    decimals=2,
    legend_alignAsTable=true,
    legend_min=true,
    legend_max=true,
    legend_current=true,
    legend_values=true,
  )
  .addTargets([
    { expr: 'kernel.all.load{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 1,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Memory Utilization',
    datasource='$datasource',
    format='kbytes',
    min=0,
    stack=true,
  )
  .addTargets([
    { expr: 'mem.util.free{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
    { expr: 'mem.util.cached{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
    { expr: 'mem.physmem{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ])
  .addSeriesOverride({
    alias: '/physmem/',
    fill: 0,
    linewidth: 2,
    stack: false,
  }), gridPos={
    x: 12,
    y: 1,
    w: 12,
    h: 7,
  }
)

.addPanel(
  grafana.row.new(
    title='CPU'
  ), gridPos={
    x: 0,
    y: 8,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Per-CPU busy (User)',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'kernel.percpu.cpu.user{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 9,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Per-CPU busy (Sys)',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'kernel.percpu.cpu.sys{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 9,
    w: 12,
    h: 7,
  }
)

.addPanel(
  grafana.row.new(
    title='Scheduler'
  ), gridPos={
    x: 0,
    y: 16,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Context switches per second',
    datasource='$datasource',
    format='ops',
    min=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'kernel.all.pswitch{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 17,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Runnable',
    datasource='$datasource',
    min=0,
    decimals=0,
    legend_show=false,
    staircase=true,
  )
  .addTargets([
    { expr: 'kernel.all.runnable{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 17,
    w: 12,
    h: 7,
  }
)

.addPanel(
  grafana.row.new(
    title='Memory'
  ), gridPos={
    x: 0,
    y: 24,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Used',
    datasource='$datasource',
    format='kbytes',
    min=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'mem.util.used{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 25,
    w: 8,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Cached',
    datasource='$datasource',
    format='kbytes',
    min=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'mem.util.cached{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 8,
    y: 25,
    w: 8,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Free',
    datasource='$datasource',
    format='kbytes',
    min=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'mem.util.free{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 16,
    y: 25,
    w: 8,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Page fault rate',
    datasource='$datasource',
    format='ops',
    min=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'mem.vmstat.pgfault{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 32,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Hard fault rate',
    datasource='$datasource',
    format='ops',
    min=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'mem.vmstat.pgmajfault{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 32,
    w: 12,
    h: 7,
  }
)

.addPanel(
  grafana.row.new(
    title='Network'
  ), gridPos={
    x: 0,
    y: 39,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Network Throughput (In)',
    datasource='$datasource',
    format='Bps',
  )
  .addTargets([
    { expr: 'network.interface.in.bytes{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 40,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Network Throughput (Out)',
    datasource='$datasource',
    format='Bps',
  )
  .addTargets([
    { expr: 'network.interface.out.bytes{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 40,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Network Drops (In)',
    datasource='$datasource',
    format='ops',
    min=0,
    decimals=0,
  )
  .addTargets([
    { expr: 'network.interface.in.drops{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 47,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Network Drops (Out)',
    datasource='$datasource',
    format='ops',
    min=0,
    decimals=0,
  )
  .addTargets([
    { expr: 'network.interface.out.drops{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 47,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Network Packets (In)',
    datasource='$datasource',
    format='ops',
    min=0,
    decimals=0,
  )
  .addTargets([
    { expr: 'network.interface.in.packets{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 54,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Network Packets (Out)',
    datasource='$datasource',
    format='ops',
    min=0,
    decimals=0,
  )
  .addTargets([
    { expr: 'network.interface.out.packets{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 54,
    w: 12,
    h: 7,
  }
)

.addPanel(
  grafana.row.new(
    title='TCP'
  ), gridPos={
    x: 0,
    y: 61,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'TCP Timeouts',
    datasource='$datasource',
    min=0,
    decimals=0,
    legend_show=false,
  )
  .addTargets([
    { expr: 'network.tcp.timeouts{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 62,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'TCP Listen Errors',
    datasource='$datasource',
    format='ops',
    min=0,
    decimals=0,
  )
  .addTargets([
    { expr: 'network.tcp.listendrops{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
    { expr: 'network.tcp.listenoverflows{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 62,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'TCP Retransmits',
    datasource='$datasource',
    format='ops',
    min=0,
    decimals=0,
  )
  .addTargets([
    { expr: 'network.tcp.retranssegs{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
    { expr: 'network.tcp.fastretrans{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
    { expr: 'network.tcp.slowstartretrans{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
    { expr: 'network.tcp.synretrans{hostname == "$host"}', legendFormat: '$metric', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 69,
    w: 24,
    h: 7,
  }
)

.addPanel(
  grafana.row.new(
    title='Disk'
  ), gridPos={
    x: 0,
    y: 76,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Disk Latency',
    datasource='$datasource',
    format='percentunit',
    min=0,
  )
  .addTargets([
    { expr: 'disk.dev.read_rawactive{hostname == "$host"}', legendFormat: 'read $instance', format: 'time_series' },
    { expr: 'disk.dev.write_rawactive{hostname == "$host"}', legendFormat: 'write $instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 77,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Disk IOPS',
    datasource='$datasource',
    format='iops',
  )
  .addTargets([
    { expr: 'disk.dev.read{hostname == "$host"}', legendFormat: 'read $instance', format: 'time_series' },
    { expr: 'disk.dev.write{hostname == "$host"}', legendFormat: 'write $instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 77,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Disk Throughput',
    datasource='$datasource',
    format='KiBs',
  )
  .addTargets([
    { expr: 'disk.dev.read_bytes{hostname == "$host"}', legendFormat: 'read $instance', format: 'time_series' },
    { expr: 'disk.dev.write_bytes{hostname == "$host"}', legendFormat: 'write $instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 84,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Disk Utilization',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'disk.dev.avactive{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 84,
    w: 12,
    h: 7,
  }
// XFS addition to pcp host overview dashboard
).addPanel(
  grafana.row.new(
    title='XFS'
  ), gridPos={
    x: 0,
    y: 91,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Inode Attribute Changes',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_attrchg{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 91,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Inode Operation Attempt',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_attempts{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 91,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Missed Inode Operations',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_missed{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 98,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Missed Inode Operations',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_missed{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 98,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Inodes Found',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_found{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 105,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Inode Duplicates',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_dup{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 13,
    y: 105,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Inode Recycles',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_frecycle{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 112,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Number of Inode Reclaims',
    datasource='$datasource',
    format='percentunit',
    min=0,
    max=1,
  )
  .addTargets([
    { expr: 'xfs.perdev.inode_ops.ig_reclaims{hostname == "$host"}', legendFormat: '$instance', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 112,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.row.new(
    title='XFS Allocations'
  ), gridPos={
    x: 0,
    y: 119,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'XFS Extent Allocations',
    datasource='$datasource',
    format='ops',
  )
  .addTargets([
    { expr: 'xfs.perdev.allocs.alloc_extent{hostname == "$host"}', legendFormat: 'alloc', format: 'time_series' },
    { expr: 'xfs.perdev.allocs.free_extent{hostname == "$host"}', legendFormat: 'free', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 120,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'XFS Block Allocations',
    datasource='$datasource',
    format='ops',
  )
  .addTargets([
    { expr: 'xfs.perdev.allocs.alloc_block{hostname == "$host"}', legendFormat: 'alloc', format: 'time_series' },
    { expr: 'xfs.perdev.allocs.free_block{hostname == "$host"}', legendFormat: 'free', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 120,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.row.new(
    title='XFS Allocation B-Tree'
  ), gridPos={
    x: 0,
    y: 127,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Allocation B-Tree Lookups/Comparisons',
    datasource='$datasource',
    format='ops',
  )
  .addTargets([
    { expr: 'xfs.perdev.alloc_btree.lookup{hostname == "$host"}', legendFormat: 'lookup', format: 'time_series' },
    { expr: 'xfs.perdev.alloc_btree.compare{hostname == "$host"}', legendFormat: 'compare', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 128,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Allocation B-Tree Record Ins/Del',
    datasource='$datasource',
    format='ops',
  )
  .addTargets([
    { expr: 'xfs.perdev.alloc_btree.insrec{hostname == "$host"}', legendFormat: 'insert', format: 'time_series' },
    { expr: 'xfs.perdev.alloc_btree.delrec{hostname == "$host"}', legendFormat: 'delete', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 128,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.row.new(
    title='XFS Inode Flushing'
  ), gridPos={
    x: 0,
    y: 135,
    w: 24,
    h: 1,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Inode Flushes',
    datasource='$datasource',
    format='ops',
  )
  .addTargets([
    { expr: 'xfs.perdev.iflush_count{hostname == "$host"}', legendFormat: 'flushes', format: 'time_series' },
  ]), gridPos={
    x: 0,
    y: 136,
    w: 12,
    h: 7,
  }
)
.addPanel(
  grafana.graphPanel.new(
    'Inode Cluster Flushes',
    datasource='$datasource',
    format='ops',
  )
  .addTargets([
    { expr: 'xfs.perdev.icluster_flushcnt{hostname == "$host"}', legendFormat: 'count', format: 'time_series' },
    { expr: 'xfs.perdev.icluster_flushinode{hostname == "$host"}', legendFormat: 'inodes', format: 'time_series' },
  ]), gridPos={
    x: 12,
    y: 136,
    w: 12,
    h: 7,
  }
)
+ {
  revision: 3,
}
