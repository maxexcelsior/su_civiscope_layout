# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class ModelWatcher < Sketchup::ModelObserver
      def onTransactionUndo(model)
        CiviscopeLayout::Core.skip_recalc = true
        CiviscopeLayout::Core.cancel_pending_recalc
        UI.start_timer(0.15, false) do
          CiviscopeLayout::Core.skip_recalc = false
          CiviscopeLayout::Core.refresh_stats_ui(model.selection)
        end
      end

      def onTransactionRedo(model)
        CiviscopeLayout::Core.skip_recalc = true
        CiviscopeLayout::Core.cancel_pending_recalc
        UI.start_timer(0.15, false) do
          CiviscopeLayout::Core.skip_recalc = false
          CiviscopeLayout::Core.refresh_stats_ui(model.selection)
        end
      end

      def onActivePathChanged(model)
        UI.start_timer(0.1, false) { CiviscopeLayout::Core.refresh_stats_ui(model.selection) }
      end

      def onTransactionCommit(model)
        return if CiviscopeLayout::Core.skip_recalc
        UI.start_timer(0.15, false) do
          CiviscopeLayout::Core.flush_pending_recalc
        end
      end
    end

  end
end
