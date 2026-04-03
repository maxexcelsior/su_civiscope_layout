# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class ModelWatcher < Sketchup::ModelObserver
      def onTransactionUndo(model)
        UI.start_timer(0.1, false) { CiviscopeLayout::Core.refresh_stats_ui(model.selection) }
      end
      
      def onTransactionRedo(model)
        UI.start_timer(0.1, false) { CiviscopeLayout::Core.refresh_stats_ui(model.selection) }
      end

      def onActivePathChanged(model)
        UI.start_timer(0.1, false) { CiviscopeLayout::Core.refresh_stats_ui(model.selection) }
      end
    end

  end
end
