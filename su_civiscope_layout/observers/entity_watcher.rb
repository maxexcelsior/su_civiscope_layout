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

    def self.attach_observers(entity)
      return unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      
      @entity_observers ||= {}
      @def_entities_observers ||= {}
      
      # Attach EntityObserver to the Instance (for Scaling/Transforming)
      id_str = self.get_short_id(entity)
      unless @entity_observers[id_str]
        obs = EntityWatcher.new
        entity.add_observer(obs)
        @entity_observers[id_str] = obs
      end
      
      # Attach EntitiesObserver to the Definition (for Push/Pull/Geometry content)
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      unless @def_entities_observers[definition.guid]
        obs = BimEntitiesWatcher.new(definition)
        definition.entities.add_observer(obs)
        @def_entities_observers[definition.guid] = obs
      end
    end

  end
end
