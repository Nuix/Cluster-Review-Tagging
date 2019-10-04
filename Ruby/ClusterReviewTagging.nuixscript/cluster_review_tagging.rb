# Menu Title: Cluster Review Tagging
# Needs Case: true
# @version 1.0.0

begin # Nx Bootstrap
  require File.join(__dir__, 'Nx.jar')
  java_import 'com.nuix.nx.NuixConnection'
  java_import 'com.nuix.nx.LookAndFeelHelper'
  java_import 'com.nuix.nx.dialogs.ChoiceDialog'
  java_import 'com.nuix.nx.dialogs.CommonDialogs'
  java_import 'com.nuix.nx.dialogs.ProcessingStatusDialog'
  java_import 'com.nuix.nx.dialogs.ProgressDialog'
  java_import 'com.nuix.nx.dialogs.TabbedCustomDialog'
  java_import 'com.nuix.nx.digest.DigestHelper'
  java_import 'com.nuix.nx.controls.models.Choice'
  LookAndFeelHelper.setWindowsIfMetal
  NuixConnection.setUtilities($utilities)
  NuixConnection.setCurrentNuixVersion(NUIX_VERSION)
end

ITEM_UTILITY = $utilities.get_item_utility

# Handles pseudoclusters with negative IDs.
#
# @param cluster [Cluster] the cluster
# @return [Integer, String] ID number, or name for negative ID pseudoclusters
def cluster_id(cluster)
  id = cluster.getId
  return 'unclusterable' if id == -1
  return 'ignorable' if id == -2

  id
end

# Class for tagging items by cluster.
# * +@annotaters+ is a Utilities.BulkAnnotater
# * +@dialog+ is an Nx ProcessDialog
# * +@cluster_run+ is a String of the cluster run name
# * +@clusters+ is a Set<Cluster>
class ClusterReviewTag
  # Tags items by cluster.
  #
  # @param settings [Hash] input from CustomExportSettings
  def initialize(settings)
    @annotater = $utilities.get_bulk_annotater
    @cluster_run = settings['cluster_run']
    @clusters = settings['clusters']
    ProgressDialog.forBlock do |progress_dialog|
      @dialog = progress_dialog
      initalize_dialog('Cluster Review Tagging')
      run
    end
  end

  protected

  # Completes the dialog, or logs the abortion.
  def close_nx
    return @dialog.setCompleted unless @dialog.abortWasRequested

    @dialog.setMainStatusAndLogIt('Aborted')
  end

  # Initializes @dialog with title.
  #
  # @param title [String]
  def initalize_dialog(title)
    @dialog.setTitle(title)
    @dialog.setLogVisible(true)
    @dialog.setTimestampLoggedMessages(true)
  end

  # Run through each cluster.
  def run
    @dialog.setMainStatusAndLogIt("Tagging #{@cluster_run}")
    @dialog.setMainProgress(0, @clusters.size)
    @clusters.each_with_index do |c, c_index|
      @dialog.setMainProgress(c_index)
      run_cluster(c)
      return nil if @dialog.abortWasRequested
    end
    close_nx
  end

  # Tags items in cluster.
  #
  # @param cluster [Cluster]
  def run_cluster(cluster)
    name = cluster_id(cluster)
    @dialog.setMainStatusAndLogIt("Tagging Cluster #{@cluster_run}-#{name}")
    sorted = ClusterSorter.new(@dialog, @cluster_run, cluster)
    items = sorted.review
    tag = "ClusterReview|#{@cluster_run}|#{name}"
    @dialog.setSubStatusAndLogIt("Tagging #{items.size} items with: #{tag}")
    @dialog.setSubProgress(0)
    @annotater.add_tag(tag, items)
  end

  # Class for sorting items in a cluster.
  # * +@dialog+ is an Nx ProgressDialog
  # * +@items+ is {"<endpoint status>" => Array<Item>}
  # * +@review+ is an Array<Item> of the items for review
  class ClusterSorter
    # @return [Array<Item>] the items for review
    attr_accessor :review

    # Sorts a cluster's items by endpoint status and finds items for review.
    #
    # @param dialog [ProgressDialog]
    # @param cluster_run [String] the cluster run name
    # @param cluster [Cluster]
    def initialize(dialog, cluster_run, cluster)
      @dialog = dialog
      @items = sort_cluster(cluster_run, cluster)
      @review = review_items
    end

    protected

    # Gets attachments from items with status endpoint-attach or thread-attach.
    #
    # @return [Array<Item>] deduplicated attachments
    def add_attachments
      @dialog.setSubStatusAndLogIt('Getting attachments')
      @dialog.setSubProgress(1, 5)
      u = ITEM_UTILITY.union(@items['endpoint-attach'], @items['thread-attach'])
      @dialog.logMessage("Finding attachments from #{u.size} items with status: endpoint-attach OR thread-attach")
      @dialog.setSubProgress(2)
      a = ITEM_UTILITY.find_descendants(u)
      @dialog.logMessage("Found #{a.size} descendants")
      @dialog.setSubProgress(3)
      d = ITEM_UTILITY.deduplicate(a)
      @dialog.logMessage("Adding #{d.size} deduplicated items (attachments)")
      @dialog.setSubProgress(4)
      d.to_a
    end

    # Gets items with endpoint status and logs count.
    #
    # @param status [String] endpoint status
    # @return [Array<Item>] items with endpoint status
    def add_status(status)
      items = @items[status]
      @dialog.logMessage("Adding #{items.size} items with status: #{status}")
      items
    end

    # Finds items for review. Items for review are:
    #  - items with status: endpoint OR endpoint-attach
    #  - descendants of an endpoint-attach or thread-attach
    #
    # @return [Array<Item>] items for review
    def review_items
      @dialog.setSubStatusAndLogIt('Finding items to review')
      @dialog.setSubProgress(0)
      items = add_status('endpoint')
      unless @items['endpoint-attach'].empty?
        items.concat(add_status('endpoint-attach'))
        items.concat(add_attachments)
      end
      @dialog.setSubProgress(1, 1)
      items
    end

    # Sorts cluster's items by endpoint status.
    #
    # @param cluster_run [String] the cluster run name
    # @param cluster [Cluster]
    # @return [Hash{String => Array<Item>}] items sorted by endpoint status
    def sort_cluster(cluster_run, cluster)
      @dialog.setSubStatusAndLogIt('Sorting by endpoint status')
      cluster_id = "#{cluster_run}-#{cluster.getId}"
      cluster_items = cluster.get_items
      items = Hash.new { |h, k| h[k] = [] }
      @dialog.setSubProgress(0, cluster_items.size)
      cluster_items.each_with_index do |ci, index|
        i = ci.get_item
        items[i.get_cluster_endpoint_status[cluster_id]] << i
        @dialog.setSubProgress(index)
      end
      items
    end
  end
end

# Class for settings dialog.
# * +@cluster_runs+ are the cluster runs from the case
# * +@dialog+ is the TabbedCustomDialog
# * +@main_tab+ is the main tab
class ClusterSettings
  # Initialize dialog.
  def initialize
    @cluster_runs = $current_case.get_cluster_runs
    @dialog = TabbedCustomDialog.new('Cluster Review Tagging')
    @main_tab = @dialog.addTab('main_tab', 'Clusters')
    # Get list of cluster runs
    choices = @cluster_runs.map(&:get_name)
    # Add cluster run selection
    @main_tab.appendComboBox('cluster_run', 'Cluster Run', choices)
    # Add table of clusters
    append_dynamic_table('clusters', 'cluster_run')
    # Validate
    @dialog.validateBeforeClosing { |v| validate_input(v) }
  end

  # Display dialog and get input.
  #
  # @return [Hash] of input
  # 'cluster_run' => [String] run name
  # 'clusters' => [Set<Cluster>] of selected clusters
  def input
    @dialog.display
    return nil if @dialog.getDialogResult == false

    @dialog.toMap
  end

  protected

  # Appends dynamic table to main tab.
  #
  # @param identifier [String] identifier for table
  # @param control [String] identifier for control that sets table records
  def append_dynamic_table(identifier, control)
    header = ['Cluster Run', 'ID', 'Items', 'Deduplicated Items']
    run_control = @main_tab.getControl(control)
    @main_tab.appendDynamicTable(identifier, 'Clusters', header, cluster_records(@cluster_runs[0].get_name)) do |record, column_index, _setting_value, _value|
      items = record.get_items
      case column_index
      when 0
        run_control.getSelectedItem
      when 1
        cluster_id(record)
      when 2
        items.size
      when 3
        ITEM_UTILITY.deduplicate(items.map(&:get_item)).size
      end
    end
    initialize_dynamic_table(identifier, run_control)
  end

  # Returns array of clusters sorted by ID.
  #
  # @param name [String] cluster run name
  # @return [Array] of clusters
  def cluster_records(name)
    run = @cluster_runs.find { |r| r.get_name == name }
    return nil if run.nil?

    run.get_clusters.to_a.sort_by!(&:get_id)
  end

  # Initializes listener to set records and check status in table.
  #
  # @param table [String] identifier for the table
  # @param run_control [java.awt.Component] Java Swing control the sets table
  def initialize_dynamic_table(table, run_control)
    table_model = @main_tab.getControl(table).getModel
    initialize_table_checks(table_model)
    run_control.addActionListener do |_e|
      table_model.uncheckDisplayedRecords
      table_model.setRecords(cluster_records(run_control.getSelectedItem))
      initialize_table_checks(table_model)
    end
  end

  # Checks all records in table, then uncheck pseudoclusters.
  #
  # @param table_model [DynamicTableModel]
  def initialize_table_checks(table_model)
    table_model.checkDisplayedRecords
    (0..1).each do |row|
      break unless table_model.getValueAt(row, 2).is_a?(String)

      table_model.setCheckedAtIndex(row, false)
    end
  end

  # Validation function for input.
  #
  # @param values [Hash] input values
  # @return [true, false] if in valid run state
  def validate_input(values)
    return CommonDialogs.showWarning('Please select clusters') if values['clusters'].empty?

    true
  end
end

begin
  settings = ClusterSettings.new.input
  ClusterReviewTag.new(settings) unless settings.nil?
end
