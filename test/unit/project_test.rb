require 'date'
require File.expand_path(File.dirname(__FILE__) + '/../test_helper')
require 'email_notifier'

class ProjectTest < Test::Unit::TestCase
  include FileSandbox
  
  def setup
    @svn = Subversion.new(:url => 'file://foo', :username => 'bob', :password => 'cha')
    @project = Project.new("lemmings")
  end

  def test_url_name
    assert_equal('somename', Project.new('some name').url_name)
    assert_equal('52somename', Project.new(' 52 some? name!').url_name)
    assert_equal('52_some_name', Project.new('52_some_name').url_name)
  end
  
  def test_properties
    @project = Project.new("lemmings", Subversion.new(:username => 'bob'))
    assert_equal("lemmings", @project.name)
    assert_equal("bob", @project.source_control.username)
  end
  
  def test_minimal_memento
    assert_equal '', @project.memento
  end

  def test_memento_with_svn
    expected_result = <<-EOL
Project.configure do |project|
  project.source_control = Subversion.new :url => 'file://foo', :username => 'bob', :password => 'cha'
end
    EOL

    @project.source_control = Subversion.new(:url => 'file://foo', :username => 'bob', :password => 'cha')
    assert_equal expected_result, @project.memento
  end

  def test_memento_with_email
    expected_result = <<-EOL
Project.configure do |project|
  project.email_notifier.emails = [
    "jss@thoughtworks.com",
    "andrew@gmail.com",
    "bob@andrews.com"
  ]
end
    EOL

    @project.add_plugin(EmailNotifier.new)
    @project.email_notifier.emails << "jss@thoughtworks.com" << "andrew@gmail.com" << "bob@andrews.com"
    assert_equal expected_result, @project.memento
  end

  def test_memento_with_custom_polling_interval
    expected_result = <<-EOL
Project.configure do |project|
  project.scheduler.polling_interval = 30.seconds
end
    EOL
    
    @project.scheduler.polling_interval = 30
    assert_equal expected_result, @project.memento
  end
  
  def test_memento_with_rake_task
    expected_result = <<-EOL
Project.configure do |project|
  project.rake_task = "build test"
end
    EOL

    @project.rake_task = 'build test'
    assert_equal expected_result, @project.memento
  end
  
  def test_memento_with_build_commands
    expected_result = <<-EOL
Project.configure do |project|
  project.build_command = "ant test"
end
    EOL

    @project.build_command = 'ant test'
    assert_equal expected_result, @project.memento
  end

  def test_default_scheduler
    assert_equal PollingScheduler, @project.scheduler.class
  end

  def test_builds
    in_sandbox do |sandbox|
      @project.path = sandbox.root

      sandbox.new :file => "build-1/build_status = success"
      sandbox.new :file => "build-10/build_status = success"
      sandbox.new :file => "build-3/build_status = failure"
      sandbox.new :file => "build-5/build_status = success"

      assert_equal("1 - success, 3 - failure, 5 - success, 10 - success",
                   @project.builds.collect {|b| "#{b.label} - #{b.status}"}.join(", "))

      assert_equal(10, @project.last_build.label)
    end
  end

  def test_builds_should_return_empty_array_when_project_has_no_builds
    in_sandbox do |sandbox|
      @project.path = sandbox.root
      assert_equal [], @project.builds
    end
  end

  def test_should_build_with_no_logs
    in_sandbox do |sandbox|
      @project.source_control = @svn
      @project.path = sandbox.root

      revision = new_revision(5)
      build = new_mock_build(5)
      build.stubs(:artifacts_directory).returns(sandbox.root)

      @project.expects(:builds).returns([])
      @svn.expects(:latest_revision).returns(revision)
      @svn.expects(:update).with(@project, revision)

      build.expects(:run)

      @project.build_if_necessary

      @svn.verify
      build.verify
    end
  end

  def test_build_if_necessary_should_generate_events
    in_sandbox do |sandbox|
      @project.source_control = @svn
      @project.path = sandbox.root

      revision = new_revision(5)
      build = new_mock_build(5)
      build.stubs(:artifacts_directory).returns(sandbox.root)

      @project.expects(:builds).returns([])
      @svn.expects(:latest_revision).returns(revision)
      @svn.expects(:update).with(@project, revision)

      build.expects(:run)

      # event expectations
      listener = Object.new

      listener.expects(:polling_source_control)
      listener.expects(:new_revisions_detected).with([revision])
      listener.expects(:build_started).with(build)
      listener.expects(:build_finished).with(build)
      listener.expects(:sleeping)

      @project.add_plugin listener

      @project.build_if_necessary

      listener.verify
    end
  end

  def test_build_should_generate_event_when_build_loop_crashes
    in_sandbox do |sandbox|
      @project.source_control = @svn
      @project.path = sandbox.root

      @project.expects(:builds).returns([])
      error = StandardError.new   
      @svn.expects(:latest_revision).raises(error)

      # event expectations
      listener = Object.new

      listener.expects(:polling_source_control)
      listener.expects(:build_loop_failed).with(error)
      listener.expects(:sleeping)

      @project.add_plugin listener
      assert_raises(error) { @project.build_if_necessary }

      listener.verify
    end
  end

  def test_should_build_when_logs_are_not_current
    in_sandbox do |sandbox|
      @project.source_control = @svn
      @project.path = sandbox.root

      @project.expects(:builds).returns([Build.new(@project, 1)])
      revision = new_revision(2)
      build = new_mock_build(2)
      build.stubs(:artifacts_directory).returns(sandbox.root)

      @svn.expects(:revisions_since).with(@project, 1).returns([revision])
      @svn.expects(:update).with(@project, revision)

      build.expects(:run)

      @project.build_if_necessary

      @svn.verify
      build.verify
    end
  end

  def test_should_not_build_when_logs_are_current
    in_sandbox do |sandbox|
      @project.source_control = @svn
      @project.path = sandbox.root

      @project.expects(:builds).returns([Build.new(@project, 2)])
      revision = new_revision(2)

      @svn.expects(:revisions_since).with(@project, 2).returns([])

      @project.build_if_necessary

      @svn.verify
    end
  end
  
  def test_either_rake_task_or_build_command_can_be_set_but_not_both
    @project.rake_task = 'foo'
    assert_raises("Cannot set build_command when rake_task is already defined") do
      @project.build_command = 'foo'
    end

    @project.rake_task = nil
    @project.build_command = 'foo'
    assert_raises("Cannot set rake_task when build_command is already defined") do
      @project.rake_task = 'foo'
    end
  end

  def test_notify_should_handle_plugin_error
    plugin = Object.new
    
    @project.plugins << plugin
    
    plugin.expects(:hey_you).raises("Plugin talking")
    
    assert_raises("Plugin error: Object: Plugin talking") { @project.notify(:hey_you) }
  end
  
  def test_notify_should_handle_multiple_plugin_errors
    plugin1 = Object.new
    plugin2 = Object.new
    
    @project.plugins << plugin1 << plugin2
    
    plugin1.expects(:hey_you).raises("Plugin 1 talking")
    plugin2.expects(:hey_you).raises("Plugin 2 talking")

    assert_raises("Plugin error:\n  Object: Plugin 1 talking\n  Object: Plugin 2 talking") { @project.notify(:hey_you) }
  end

  def test_determine_builder_state
    ProjectBlocker.expects(:block?).with(@project).returns(true)
    assert_equal Status::NOT_RUNNING, @project.builder_state
    
    ProjectBlocker.expects(:block?).with(@project).returns(false)
    assert_equal Status::RUNNING, @project.builder_state
  end

  def test_builder_and_build_states_tag
    build = Object.new    
    build.expects(:label).at_least(1).returns('2')
    build.expects(:status).at_least(1).returns('pingpong')
    
    @project.expects(:builder_state_and_activity).at_least(1).returns('running (sleeping)')
    @project.expects(:builds).at_least(1).returns([build])
    assert_equal "running(sleeping)2pingpong", @project.builder_and_build_states_tag
  end
  
  def test_return_builder_activity
    @builder_status = Object.new
    @project.builder_status = @builder_status
    
    ProjectBlocker.expects(:block?).with(@project).returns(false) 
    @builder_status.expects(:status).returns(:working)
    assert_equal :working, @project.builder_activity
  end
    
  def test_return_not_running_as_builder_activity_when_builder_is_not_running
    ProjectBlocker.expects(:block?).with(@project).returns(true)  
    assert_equal Status::NOT_RUNNING, @project.builder_activity
  end
  
  def test_build_should_return_nil_if_lock_build_blocker_failed 
      BuildBlocker.expects(:block).with(@project).raises()
      BuildBlocker.expects(:release).with(@project)
      assert_nil @project.build(Object.new) 
  end

  def test_should_not_return_builder_activity_when_status_is_not_running
    @project.expects(:builder_state).at_least(1).returns(Status::NOT_RUNNING)
    @project.expects(:builder_activity).times(0)

    assert_equal "not started", @project.builder_state_and_activity
  end

  def test_should_return_builder_activity_when_status_is_running
    @project.expects(:builder_state).at_least(1).returns(Status::RUNNING)
    @project.expects(:builder_activity).at_least(1).returns('mock status')

    assert_equal "running (mock status)", @project.builder_state_and_activity
  end
      
  private
  def new_revision(number)
    Revision.new(number, 'alex', DateTime.new(2005, 1, 1), 'message', [])
  end

  def new_mock_build(number)
    build = Object.new
    Build.expects(:new).with(@project, number).returns(build)
    build
  end
end

