class RbStory < Issue
    unloadable

    acts_as_list

    def self.find_params(options)
      project_id = options.delete(:project_id)
      sprint_ids = options.delete(:sprint_id)
      include_backlog = options.delete(:include_backlog)

      sprint_ids = RbSprint.open_sprints(Project.find(project_id)).collect{|s| s.id} if project_id && sprint_ids == :open

      project_id = nil if !include_backlog && sprint_ids
      sprint_ids = [sprint_ids] if sprint_ids && !sprint_ids.is_a?(Array)

      raise "Specify either sprint or project id" unless (sprint_ids || project_id)

      options[:joins] = [options[:joins]] unless options[:joins].is_a?(Array)

      conditions = []
      parameters = []
      options[:joins] << :project

      if project_id
        conditions << "(tracker_id in (?) and fixed_version_id is NULL and #{IssueStatus.table_name}.is_closed = ? and (#{Project.find(project_id).project_condition(true)}))"
        parameters += [RbStory.trackers, false]
        options[:joins] << :status
      end

      if sprint_ids
        conditions << "(tracker_id in (?) and fixed_version_id in (?))"
        parameters += [RbStory.trackers, sprint_ids]
      end

      conditions = conditions.join(' or ')

      visible = []
      visible = sprint_ids.collect{|s| Issue.visible_condition(User.current, :project => Version.find(s).project, :with_subprojects => true) } if sprint_ids
      visible << Issue.visible_condition(User.current, :project => Project.find(project_id), :with_subprojects => true) if project_id
      visible = visible.join(' or ')
      visible = " and (#{visible})" unless visible == ''

      conditions += visible

      options[:conditions] = [options[:conditions]] if options[:conditions] && !options[:conditions].is_a?(Array)
      if options[:conditions]
        conditions << " and (" + options[:conditions].delete_at(0) + ")"
        parameters += options[:conditions]
      end

      options[:conditions] = [conditions] + parameters

      options[:joins].compact!
      options[:joins].uniq!
      options.delete(:joins) if options[:joins].size == 0

      return options
    end

    # this forces NULLS-LAST ordering
    ORDER = 'case when issues.position is null then 1 else 0 end ASC, case when issues.position is NULL then issues.id else issues.position end ASC'

    def self.backlog(options={})
      stories = []

      RbStory.find(:all, RbStory.find_params(options.merge(:order => RbStory::ORDER))).each_with_index {|story, i|
        story.rank = i + 1
        stories << story
      }

      return stories
    end

    def self.product_backlog(project, limit=nil)
      return RbStory.backlog(:project_id => project.id, :limit => limit)
    end

    def self.sprint_backlog(sprint, options={})
      return RbStory.backlog(options.merge(:sprint_id => sprint.id))
    end

    def self.backlogs_by_sprint(project, sprints, options={})
        ret = RbStory.backlog(project.id, sprints.map {|s| s.id }, options)
        sprint_of = {}
        ret.each do |backlog|
            sprint_of[backlog.fixed_version_id] ||= []
            sprint_of[backlog.fixed_version_id].push(backlog)
        end
        return sprint_of
    end

    def self.stories_open(project)
      stories = []

      RbStory.find(:all,
            :order => RbStory::ORDER,
            :conditions => ["project_id = ? AND tracker_id in (?) and is_closed = ?",project.id,RbStory.trackers,false],
            :joins => :status).each_with_index {|story, i|
        story.rank = i + 1
        stories << story
      }
      return stories
    end

    def self.create_and_position(params)
      attribs = params.select{|k,v| k != 'prev_id' and k != 'id' and RbStory.column_names.include? k }
      attribs = Hash[*attribs.flatten]
      s = RbStory.new(attribs)
      s.save!
      s.move_after(params['prev_id'])
      return s
    end

    def self.find_all_updated_since(since, project_id)
      find(:all,
           :conditions => ["project_id = ? AND updated_on > ? AND tracker_id in (?)", project_id, Time.parse(since), trackers],
           :order => "updated_on ASC")
    end

    def self.trackers(type = :array)
      # somewhere early in the initialization process during first-time migration this gets called when the table doesn't yet exist
      trackers = []
      if ActiveRecord::Base.connection.tables.include?('settings')
        trackers = Setting.plugin_redmine_backlogs[:story_trackers]
        trackers = [] if trackers.blank?
      end

      return trackers.join(',') if type == :string

      return trackers.map { |tracker| Integer(tracker) }
    end

    def tasks
      return RbTask.tasks_for(self.id)
    end

    def move_after(prev_id)
      # remove so the potential 'prev' has a correct position
      remove_from_list

      if prev_id.to_s == ''
        prev = nil
      else
        prev = RbStory.find(prev_id)
      end

      # if it's the first story, move it to the 1st position
      if prev.blank?
        insert_at
        move_to_top

      # if its predecessor has no position (shouldn't happen), make it
      # the last story
      elsif !prev.in_list?
        insert_at
        move_to_bottom

      # there's a valid predecessor
      else
        insert_at(prev.position + 1)
      end
    end

    def set_points(p)
        self.init_journal(User.current)

        if p.blank? || p == '-'
            self.update_attribute(:story_points, nil)
            return
        end

        if p.downcase == 's'
            self.update_attribute(:story_points, 0)
            return
        end

        p = Integer(p)
        if p >= 0
            self.update_attribute(:story_points, p)
            return
        end
    end

    def points_display(notsized='-')
        # For reasons I have yet to uncover, activerecord will
        # sometimes return numbers as Fixnums that lack the nil?
        # method. Comparing to nil should be safe.
        return notsized if story_points == nil || story_points.blank?
        return 'S' if story_points == 0
        return story_points.to_s
    end

    def task_status
        closed = 0
        open = 0
        self.descendants.each {|task|
            if task.closed?
                closed += 1
            else
                open += 1
            end
        }
        return {:open => open, :closed => closed}
    end

    def update_and_position!(params)
      attribs = params.select{|k,v| k != 'id' && k != 'project_id' && RbStory.column_names.include?(k) }
      attribs = Hash[*attribs.flatten]
      result = journalized_update_attributes attribs
      if result and params[:prev]
        move_after(params[:prev])
      end
      result
    end

  def rank=(r)
    @rank = r
  end

  def rank
    @rank ||= Issue.count(RbStory.find_params(
      :sprint_id => self.fixed_version_id,
      :project_id => self.project.id,
      :conditions => self.position.blank? ? ['(issues.position is NULL and issues.id <= ?) or not issues.position is NULL', self.id] : ['not issues.position is NULL and issues.position <= ?', self.position]
    ))

    return @rank
  end

  def self.at_rank(rank, options)
    return RbStory.find(:first, RbStory.find_params(options.merge(
                      :order => RbStory::ORDER,
                      :limit => 1,
                      :offset => rank - 1)))
  end

  def burndown(sprint=nil)
    return nil unless self.is_story?
    sprint ||= self.fixed_version.becomes(RbSprint) if self.fixed_version
    return nil if sprint.nil?

    return Rails.cache.fetch("RbIssue(#{self.id}).burndown(#{sprint.id})") {
      bd = {}

      if sprint.has_burndown?
        days = sprint.days(:active)

        status = history(:status_id, days).collect{|s| s ? IssueStatus.find(s) : nil}

        series = Backlogs::MergedArray.new
        series.merge(:in_sprint => history(:fixed_version_id, days).collect{|s| s == sprint.id})
        series.merge(:points => history(:story_points, days))
        series.merge(:open => status.collect{|s| s ? !s.is_closed? : false})
        series.merge(:accepted => status.collect{|s| s ? (s.backlog_is?(:success)) : false})
        series.merge(:hours => ([0] * (days.size + 1)))

        tasks.each{|task| series.add(:hours => task.burndown(sprint)) }

        series.each {|datapoint|
          if datapoint.in_sprint
            datapoint.hours = 0 unless datapoint.open
            datapoint.points_accepted = (datapoint.accepted ? datapoint.points : nil)
            datapoint.points_resolved = (datapoint.accepted || datapoint.hours.to_f == 0.0 ? datapoint.points : nil)
          else
            datapoint.nilify
            datapoint.points_accepted = nil
            datapoint.points_resolved = nil
          end
        }

        # collect points on this sprint
        bd[:points] = series.series(:points)
        bd[:points_accepted] = series.series(:points_accepted)
        bd[:points_resolved] = series.series(:points_resolved)
        bd[:hours] = series.collect{|datapoint| datapoint.open ? datapoint.hours : nil}
      end

      bd
    }
  end

end
