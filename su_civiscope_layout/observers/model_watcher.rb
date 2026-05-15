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
        skip = CiviscopeLayout::Core.skip_recalc
        puts "[DEBUG-FL] ModelWatcher#onTransactionCommit skip_recalc=#{skip}"
        return if skip
        puts "[DEBUG-FL] ModelWatcher#onTransactionCommit → starting 0.15s flush timer"
        UI.start_timer(0.15, false) do
          puts "[DEBUG-FL] ModelWatcher COMMIT-TIMER fired → flush_pending_recalc"
          CiviscopeLayout::Core.flush_pending_recalc
        end
      end
    end

  end
end
