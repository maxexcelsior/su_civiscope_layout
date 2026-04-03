# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(selection)
        CiviscopeLayout::Core.refresh_stats_ui(selection)
      end
      
      def onSelectionCleared(selection)
        CiviscopeLayout::Core.refresh_stats_ui(selection)
      end
    end

  end
end
