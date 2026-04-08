# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class EntityWatcher < Sketchup::EntityObserver
      def onElementModified(*args)
        entity = args.last
        return if CiviscopeLayout::Core.skip_recalc
        CiviscopeLayout::Core.schedule_auto_recalc(entity)
      end
      
      def onTransformationChanged(*args)
        entity = args.last
        return if CiviscopeLayout::Core.skip_recalc
        CiviscopeLayout::Core.schedule_auto_recalc(entity)
      end
      
      def onChangeEntity(*args)
        entity = args.last
        return if CiviscopeLayout::Core.skip_recalc
        CiviscopeLayout::Core.schedule_auto_recalc(entity)
      end
    end

    class BimEntitiesWatcher < Sketchup::EntitiesObserver
      def initialize(definition)
        @definition = definition
      end
      
      def onElementAdded(*args); trigger_update; end
      def onElementModified(*args); trigger_update; end
      def onElementRemoved(*args); trigger_update; end
      
      def trigger_update
        return if CiviscopeLayout::Core.skip_recalc
        # When geometry inside definition changes, notify all instances
        @definition.instances.each do |inst|
          CiviscopeLayout::Core.schedule_auto_recalc(inst)
        end
      end
    end

    def self.schedule_auto_recalc(entity)
      return unless entity.valid?
      UI.stop_timer(@timer_id) if @timer_id
      @timer_id = UI.start_timer(0.2, false) do
        @timer_id = nil
        self.auto_recalculate(entity)
      end
    end

    # 附加实体观察者（委托给 ObserverManager）
    def self.attach_observers(entity)
      ObserverManager.attach_entity_observers(entity)
    end

  end
end
