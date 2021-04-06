require "active_support/concern"

module RocketJob
  module Batch
    module Categories
      extend ActiveSupport::Concern

      included do
        after_initialize :rocketjob_categories_assign, if: :new_record?
        after_initialize :rocketjob_categories_migrate, unless: :new_record?
        before_perform :rocketjob_categories_input_render
        after_perform :rocketjob_categories_output_render

        # List of categories that this job can load input data into
        embeds_many :input_categories, class_name: "RocketJob::Category::Input"

        # List of categories that this job can save output data into
        embeds_many :output_categories, class_name: "RocketJob::Category::Output"

        # Internal attributes
        class_attribute :defined_input_categories, instance_accessor: false, instance_predicate: false
        class_attribute :defined_output_categories, instance_accessor: false, instance_predicate: false
      end

      module ClassMethods
        # Define a new input category
        # @see RocketJob::Category::Input
        def input_category(**args)
          category = RocketJob::Category::Input.new(**args)
          if defined_input_categories.nil?
            self.defined_input_categories = [category]
          else
            rocketjob_categories_set(category, defined_input_categories)
          end
        end

        # Define a new output category
        # @see RocketJob::Category::Output
        def output_category(**args)
          category = RocketJob::Category::Output.new(**args)
          if defined_output_categories.nil?
            self.defined_output_categories = [category]
          else
            rocketjob_categories_set(category, defined_output_categories)
          end
        end

        # Builds this job instance from the supplied properties hash that may contain input and output categories.
        # Keeps the defaults and merges in settings without replacing existing categories.
        def from_properties(properties)
          return super(properties) unless properties.key?("input_categories") || properties.key?("output_categories")

          properties        = properties.dup
          input_categories  = properties.delete("input_categories")
          output_categories = properties.delete("output_categories")
          job               = new(properties)

          input_categories&.each do |category_properties|
            category_name = (category_properties["name"] || :main).to_sym
            if job.input_category?(category_name)
              category = job.input_category(category_name)
              category_properties.each { |key, value| category.public_send("#{key}=".to_sym, value) }
            else
              job.input_categories << Category::Input.new(category_properties.symbolize_keys)
            end
          end

          output_categories&.each do |category_properties|
            category_name = (category_properties["name"] || :main).to_sym
            if job.output_category?(category_name)
              category = job.output_category(category_name)
              category_properties.each { |key, value| category.public_send("#{key}=".to_sym, value) }
            else
              job.output_categories << Category::Output.new(category_properties.symbolize_keys)
            end
          end

          job
        end

        private

        def rocketjob_categories_set(category, categories)
          index = categories.find_index { |cat| cat.name == category.name }
          index ? categories[index] = category : categories << category
          category
        end
      end

      def input_category(category_name = :main)
        category_name = category_name.to_sym
        category      = nil
        # .find does not work against this association
        input_categories.each { |catg| category = catg if catg.name == category_name }
        unless category
          # Auto-register main input category if missing
          if category_name == :main
            category              = Category::Input.new
            self.input_categories = [category]
          else
            raise(ArgumentError, "Unknown Input Category: #{category_name.inspect}. Registered categories: #{input_categories.collect(&:name).join(',')}")
          end
        end
        category
      end

      def output_category(category_name = :main)
        category_name = category_name.to_sym
        category      = nil
        # .find does not work against this association
        output_categories.each { |catg| category = catg if catg.name == category_name }
        unless category
          raise(ArgumentError, "Unknown Output Category: #{category_name.inspect}. Registered categories: #{output_categories.collect(&:name).join(',')}")
        end
        category
      end

      # Returns [true|false] whether the named category has already been defined
      def input_category?(category_name)
        category_name = category_name.to_sym
        # .find does not work against this association
        input_categories.each { |catg| return true if catg.name == category_name }
        false
      end

      def output_category?(category_name)
        category_name = category_name.to_sym
        # .find does not work against this association
        output_categories.each { |catg| return true if catg.name == category_name }
        false
      end

      private

      def rocketjob_categories_assign
        # Input categories defaults to :main if none was set in the class
        if input_categories.empty?
          self.input_categories =
            if self.class.defined_input_categories
              self.class.defined_input_categories.deep_dup
            else
              [RocketJob::Category::Input.new]
            end
        end

        return if !self.class.defined_output_categories || !output_categories.empty?

        # Input categories defaults to nil if none was set in the class
        self.output_categories = self.class.defined_output_categories.deep_dup
      end

      # Render the output from the perform.
      def rocketjob_categories_output_render
        return if @rocket_job_output.nil?

        # TODO: ..
        return unless output_categories
        return if output_categories.empty?

        @rocket_job_output = rocketjob_categories_output_render_row(@rocket_job_output)
      end

      # Parse the input data before passing to the perform method
      def rocketjob_categories_input_render
        return if @rocket_job_input.nil?

        @rocket_job_input = rocketjob_categories_input_render_row(@rocket_job_input)
      end

      def rocketjob_categories_input_render_row(row)
        return if row.nil?

        category = input_category
        return row if category.nil? || !category.tabular?
        return nil if row.blank?

        tabular = category.tabular

        # Return the row as-is if the required header has not yet been set.
        if tabular.header?
          raise(ArgumentError,
                "The tabular header columns _must_ be set before attempting to parse data that requires it.")
        end

        tabular.record_parse(row)
      end

      def rocketjob_categories_output_render_row(row)
        return if row.nil?

        if row.is_a?(Batch::Result)
          category  = output_category(row.category)
          row.value = category.tabular.render(row.value) if category.tabular?
          return row
        end

        if row.is_a?(Batch::Results)
          results = Batch::Results.new
          row.each { |result| results << rocketjob_categories_output_render_row(result) }
          return results
        end

        category = output_category
        return row unless category.tabular?
        return nil if row.blank?

        category.tabular.render(row)
      end

      # Migrate existing v4 batch jobs to v5.0
      def rocketjob_categories_migrate
        return unless attribute_present?(:input_categories) && self[:input_categories]&.first.is_a?(Symbol)

        serializer = :none
        if attribute_present?(:compress)
          serializer = :compress if self[:compress]
          remove_attribute(:compress)
        end

        if attribute_present?(:encrypt)
          serializer = :encrypt if self[:encrypt]
          remove_attribute(:encrypt)
        end

        slice_size = 100
        if attribute_present?(:slice_size)
          slice_size = self[:slice_size].to_i
          remove_attribute(:slice_size)
        end

        existing                = self[:input_categories]
        self[:input_categories] = []
        self[:input_categories] = existing.collect do |category_name|
          RocketJob::Category::Input.new(name: category_name, serializer: serializer, slice_size: slice_size).as_document
        end

        collect_output = false
        if attribute_present?(:collect_output)
          collect_output = self[:collect_output]
          remove_attribute(:collect_output)
        end

        collect_nil_output = true
        if attribute_present?(:collect_nil_output)
          collect_nil_output = self[:collect_nil_output]
          remove_attribute(:collect_nil_output)
        end

        existing                 = self[:output_categories]
        self[:output_categories] = []
        if existing.blank?
          if collect_output
            self[:output_categories] = [RocketJob::Category::Output.new(nils: collect_nil_output).as_document]
          end
        elsif existing.first.is_a?(Symbol)
          self[:output_categories] = existing.collect do |category_name|
            RocketJob::Category::Output.new(name: category_name, serializer: serializer, nils: collect_nil_output).as_document
          end
        end
      end
    end
  end
end
