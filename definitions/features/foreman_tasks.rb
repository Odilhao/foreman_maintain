class Features::ForemanTasks < ForemanMaintain::Feature
  MIN_AGE = 30
  TIMEOUT_FOR_TASKS_STATUS = 300
  RETRY_INTERVAL_FOR_TASKS_STATE = 10

  SAFE_TO_DELETE = %w[
    Actions::Katello::Host::GenerateApplicability
    Actions::Katello::RepositorySet::ScanCdn
    Actions::Katello::Host::Hypervisors
    Actions::Katello::Host::HypervisorsUpdate
    Actions::Foreman::Host::ImportFacts
    Actions::Candlepin::ListenOnCandlepinEvents
    Actions::Katello::EventQueue::Monitor
  ].freeze

  EXCLUDE_ACTIONS_FOR_RUNNING_TASKS = %w[
    Actions::Candlepin::ListenOnCandlepinEvents
    Actions::Katello::EventQueue::Monitor
    Actions::Insights::EmailPoller
    ForemanInventoryUpload::Async::GenerateAllReportsJob
    ForemanInventoryUpload::Async::GenerateReportJob
    ForemanInventoryUpload::Async::QueueForUploadJob
    ForemanInventoryUpload::Async::UploadReportJob
    InsightsCloud::Async::InsightsClientStatusAging
    InsightsCloud::Async::InsightsFullSync
    InsightsCloud::Async::InsightsResolutionsSync
    InsightsCloud::Async::InsightsRulesSync
    InsightsCloud::Async::InsightsScheduledSync
    InventorySync::Async::InventoryFullSync
    InventorySync::Async::InventoryHostsSync
    InventorySync::Async::InventoryScheduledSync
    InventorySync::Async::InventorySelfHostSync
  ].freeze

  metadata do
    label :foreman_tasks

    confine do
      find_package(foreman_plugin_name('foreman-tasks'))
    end
  end

  def backup_tasks(state)
    backup_table('dynflow_execution_plans', state, 'uuid') { |status| yield(status) }
    backup_table('dynflow_steps', state) { |status| yield(status) }
    backup_table('dynflow_actions', state) { |status| yield(status) }

    yield('Backup Tasks [running]')
    export_csv("SELECT * FROM foreman_tasks_tasks WHERE #{condition(state)}",
               'foreman_tasks_tasks.csv', state)
    yield('Backup Tasks [DONE]')
    @backup_dir = nil
  end

  def running_tasks_count
    actions_to_exclude = quotize(EXCLUDE_ACTIONS_FOR_RUNNING_TASKS)
    sql = <<-SQL
      SELECT count(*) AS count
        FROM foreman_tasks_tasks
        WHERE state IN ('running') AND
        label NOT IN (#{actions_to_exclude})
    SQL
    feature(:foreman_database).query(sql).first['count'].to_i
  end

  def paused_tasks_count(ignored_tasks = [])
    sql = <<-SQL
      SELECT count(*) AS count
        FROM foreman_tasks_tasks
        WHERE state IN ('paused') AND result IN ('error')
    SQL
    unless ignored_tasks.empty?
      sql << "AND label NOT IN (#{quotize(ignored_tasks)})"
    end
    feature(:foreman_database).query(sql).first['count'].to_i
  end

  def count(state)
    feature(:foreman_database).query(<<-SQL).first['count'].to_i
     SELECT count(*) AS count FROM foreman_tasks_tasks WHERE #{condition(state)}
    SQL
  end

  def delete(state)
    tasks_condition = condition(state)

    sql = <<-SQL
      DELETE FROM dynflow_steps USING foreman_tasks_tasks WHERE (foreman_tasks_tasks.external_id = dynflow_steps.execution_plan_uuid::varchar) AND #{tasks_condition};
      DELETE FROM dynflow_actions USING foreman_tasks_tasks WHERE (foreman_tasks_tasks.external_id = dynflow_actions.execution_plan_uuid::varchar) AND #{tasks_condition};
      DELETE FROM dynflow_execution_plans USING foreman_tasks_tasks WHERE (foreman_tasks_tasks.external_id = dynflow_execution_plans.uuid::varchar) AND #{tasks_condition};
      DELETE FROM foreman_tasks_tasks WHERE #{tasks_condition};
      -- Delete locks and links which may now be orphaned
      DELETE FROM foreman_tasks_locks as ftl where ftl.task_id NOT IN (SELECT id FROM foreman_tasks_tasks);
    SQL

    if check_min_version(foreman_plugin_name('foreman-tasks'), '4.0.0')
      sql += 'DELETE FROM foreman_tasks_links as ftl ' \
             'where ftl.task_id NOT IN (SELECT id FROM foreman_tasks_tasks);'
    end

    feature(:foreman_database).psql("BEGIN; #{sql}; COMMIT;")

    count(state)
  end

  def condition(state)
    raise 'Invalid State' unless valid(state)

    if state == :old
      old_tasks_condition
    elsif state == :paused
      paused_tasks_condition
    else
      tasks_condition(state)
    end
  end

  def resume_task_using_hammer
    if feature(:satellite) && feature(:satellite).current_minor_version == '6.8'
      feature(:hammer).run('task resume --search "" --fields="Total tasks resumed"')
    else
      feature(:hammer).run('task resume --fields="Total tasks resumed"')
    end
  end

  def fetch_tasks_status(state, spinner)
    Timeout.timeout(TIMEOUT_FOR_TASKS_STATUS) do
      check_task_count(state, spinner)
    end
  rescue Timeout::Error => e
    logger.error e.message
    puts "\nTimeout: #{e.message}. Try again."
  end

  def services
    feature(:dynflow_sidekiq) ? [] : [system_service(service_name, 30)]
  end

  def service_name
    check_min_version('foreman', '1.17') ? 'dynflowd' : 'foreman-tasks'
  end

  private

  def check_task_count(state, spinner)
    loop do
      spinner.update "Try checking status of #{state} task(s)"
      task_count = call_tasks_count_by_state(state)
      break if task_count == 0
      puts "\nThere are #{task_count} #{state} tasks."
      spinner.update "Waiting #{RETRY_INTERVAL_FOR_TASKS_STATE} seconds before retry."
      sleep RETRY_INTERVAL_FOR_TASKS_STATE
    end
  rescue StandardError => e
    logger.error e.message
  end

  def call_tasks_count_by_state(state)
    case state
    when 'running'
      running_tasks_count
    when 'paused'
      paused_tasks_count
    else
      logger.error "No count method defined for state #{state}."
      raise "Unsupported for state #{state}."
    end
  end

  def parent_backup_dir
    File.expand_path(ForemanMaintain.config.backup_dir)
  end

  def backup_dir(state)
    @backup_dir ||=
      "#{parent_backup_dir}/backup-tasks/#{state}/#{Time.now.strftime('%Y-%m-%d_%H-%M-%S')}"
  end

  def backup_table(table, state, fkey = 'execution_plan_uuid')
    yield("Backup #{table} [running]")
    sql = "SELECT #{table}.* FROM foreman_tasks_tasks JOIN #{table} ON\
       (foreman_tasks_tasks.external_id = #{table}.#{fkey}::varchar)"
    export_csv(sql, "#{table}.csv", state)
    yield("Backup #{table} [DONE]")
  end

  def export_csv(sql, file_name, state)
    dir = prepare_for_backup(state)
    filepath = "#{dir}/#{file_name}"
    csv_output = feature(:foreman_database).query_csv(sql)
    File.open(filepath, 'w') do |f|
      f.write(csv_output)
      f.close
    end
    execute("bzip2 #{filepath} -c -9 > #{filepath}.bz2")
    FileUtils.rm_rf(filepath)
  end

  def old_tasks_condition(state = "'stopped', 'paused'")
    "foreman_tasks_tasks.state IN (#{state}) AND " \
       "foreman_tasks_tasks.started_at < CURRENT_DATE - INTERVAL '#{MIN_AGE} days'"
  end

  def paused_tasks_condition(state = "'paused'")
    "foreman_tasks_tasks.state IN (#{state})"
  end

  def prepare_for_backup(state)
    dir = backup_dir(state)
    execute("mkdir -p #{dir}")
    dir
  end

  def quotize(array)
    array.map { |el| "'#{el}'" }.join(',')
  end

  def tasks_condition(state)
    safe_to_delete_tasks = quotize(SAFE_TO_DELETE)
    "foreman_tasks_tasks.state = '#{state}' AND " \
    "foreman_tasks_tasks.label IN (#{safe_to_delete_tasks})"
  end

  def valid(state)
    %w[old planning pending paused].include?(state.to_s)
  end
end
