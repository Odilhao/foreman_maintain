module ForemanMaintain::Scenarios
  module Content
    class ContentBase < ForemanMaintain::Scenario
      def enable_and_start_services
        add_step(Procedures::Service::Enable.
                 new(:only => Features::Pulpcore.pulpcore_migration_services))
        add_step(Procedures::Service::Start.
                 new(:include => Features::Pulpcore.pulpcore_migration_services))
      end

      def disable_and_stop_services
        add_step(Procedures::Service::Stop.
                 new(:only => Features::Pulpcore.pulpcore_migration_services))
        add_step(Procedures::Service::Disable.
                 new(:only => Features::Pulpcore.pulpcore_migration_services))
      end
    end

    class Prepare < ContentBase
      metadata do
        label :content_prepare
        description 'Prepare content for Pulp 3'
        manual_detection
      end

      def compose
        if feature(:satellite) && feature(:satellite).at_least_version?('6.9')
          enable_and_start_services
          add_step(Procedures::Content::Prepare.new(quiet: quiet?))
          disable_and_stop_services
        elsif !feature(:satellite)
          add_step(Procedures::Content::Prepare.new(quiet: quiet?))
        end
      end

      private

      def quiet?
        !!context.get(:quiet)
      end
    end

    class Switchover < ContentBase
      metadata do
        label :content_switchover
        description 'Switch support for certain content from Pulp 2 to Pulp 3'
        manual_detection
      end

      def compose
        add_step_with_context(Procedures::Content::Switchover)
        add_step(Procedures::Foreman::ApipieCache)
      end
    end

    class PrepareAbort < ContentBase
      metadata do
        label :content_prepare_abort
        description 'Abort all running Pulp 2 to Pulp 3 migration tasks'
        manual_detection
      end

      def compose
        if !feature(:satellite) || feature(:satellite).at_least_version?('6.9')
          enable_and_start_services if feature(:satellite)
          add_step(Procedures::Content::PrepareAbort)
          disable_and_stop_services if feature(:satellite)
        end
      end
    end

    class MigrationStats < ContentBase
      metadata do
        label :content_migration_stats
        description 'Retrieve Pulp 2 to Pulp 3 migration statistics'
        manual_detection
      end

      def compose
        if !feature(:satellite) || feature(:satellite).at_least_version?('6.9')
          add_step(Procedures::Content::MigrationStats)
        end
      end
    end

    class MigrationReset < ContentBase
      metadata do
        label :content_migration_reset
        description 'Reset the Pulp 2 to Pulp 3 migration data (pre-switchover)'
        manual_detection
      end

      def compose
        if feature(:satellite) && feature(:satellite).at_least_version?('6.9')
          enable_and_start_services
          add_step(Procedures::Content::MigrationReset)
          disable_and_stop_services
        elsif !feature(:satellite)
          add_step(Procedures::Content::MigrationReset)
        end
      end
    end

    class CleanupRepositoryMetadata < ContentBase
      metadata do
        label :cleanup_repository_metadata
        description 'Remove old leftover repository metadata'
        param :remove_files, 'Actually remove the files? Otherwise a dryrun is performed.'

        manual_detection
      end

      def compose
        add_step_with_context(Procedures::Pulp::CleanupOldMetadataFiles)
      end

      def set_context_mapping
        context.map(:remove_files, Procedures::Pulp::CleanupOldMetadataFiles => :remove_files)
      end
    end

    class RemovePulp2 < ContentBase
      metadata do
        label :content_remove_pulp2
        description 'Remove Pulp2 and mongodb packages and data'
        param :assumeyes, 'Do not ask for confirmation'
        manual_detection
      end

      def set_context_mapping
        context.map(:assumeyes, Procedures::Pulp::Remove => :assumeyes)
        context.map(:assumeyes, Procedures::Content::FixPulpcoreArtifactOwnership => :assumeyes)
      end

      def compose
        add_step_with_context(Procedures::Pulp::Remove)
        add_step_with_context(Procedures::Content::FixPulpcoreArtifactOwnership)
      end
    end

    class FixPulpcoreArtifactOwnership < ContentBase
      metadata do
        label :content_fix_pulpcore_artifact_ownership
        description 'Fix Pulpcore artifact ownership to be pulp:pulp'
        param :assumeyes, 'Do not ask for confirmation'
        manual_detection
      end

      def set_context_mapping
        context.map(:assumeyes, Procedures::Content::FixPulpcoreArtifactOwnership => :assumeyes)
      end

      def compose
        add_step_with_context(Procedures::Content::FixPulpcoreArtifactOwnership)
      end
    end
  end
end
