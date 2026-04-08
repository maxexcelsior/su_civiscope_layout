# 编码：UTF-8
module CiviscopeLayout
  module Core
    module ObserverManager
      
      # 观察者实例存储
      @entity_observers = {}
      @def_entities_observers = {}
      @selection_observer = nil
      @model_observer = nil
      
      # ==========================================
      # 清理所有观察者
      # ==========================================
      def self.cleanup_all_observers(model)
        return unless model
        
        # 清理选择观察者
        if @selection_observer
          begin
            model.selection.remove_observer(@selection_observer)
          rescue => e
            puts "[Civiscope ObserverManager] 清理选择观察者失败: #{e.message}"
          end
          @selection_observer = nil
        end
        
        # 清理模型观察者
        if @model_observer
          begin
            model.remove_observer(@model_observer)
          rescue => e
            puts "[Civiscope ObserverManager] 清理模型观察者失败: #{e.message}"
          end
          @model_observer = nil
        end
        
        # 清理实体观察者
        @entity_observers.each do |id_str, obs|
          begin
            # 实体可能已失效，需要检查
            entity = model.entities.find { |e| CiviscopeLayout::Core.get_short_id(e) == id_str }
            if entity && entity.valid?
              entity.remove_observer(obs)
            end
          rescue => e
            puts "[Civiscope ObserverManager] 清理实体观察者失败 (#{id_str}): #{e.message}"
          end
        end
        @entity_observers.clear
        
        # 清理定义观察者
        @def_entities_observers.each do |guid, obs|
          begin
            # 查找对应的定义
            definition = model.definitions.find { |d| d.guid == guid }
            if definition
              definition.entities.remove_observer(obs)
            end
          rescue => e
            puts "[Civiscope ObserverManager] 清理定义观察者失败 (#{guid}): #{e.message}"
          end
        end
        @def_entities_observers.clear
        
        puts "[Civiscope ObserverManager] 所有观察者已清理"
      end
      
      # ==========================================
      # 注册选择观察者
      # ==========================================
      def self.register_selection_observer(model)
        return unless model
        
        # 先清理旧的观察者（如果存在）
        if @selection_observer
          begin
            model.selection.remove_observer(@selection_observer)
          rescue
          end
        end
        
        # 注册新的观察者
        @selection_observer = SelectionWatcher.new
        model.selection.add_observer(@selection_observer)
        
        puts "[Civiscope ObserverManager] 选择观察者已注册"
      end
      
      # ==========================================
      # 注册模型观察者
      # ==========================================
      def self.register_model_observer(model)
        return unless model
        
        # 先清理旧的观察者（如果存在）
        if @model_observer
          begin
            model.remove_observer(@model_observer)
          rescue
          end
        end
        
        # 注册新的观察者
        @model_observer = ModelWatcher.new
        model.add_observer(@model_observer)
        
        puts "[Civiscope ObserverManager] 模型观察者已注册"
      end
      
      # ==========================================
      # 注册所有核心观察者
      # ==========================================
      def self.register_all_observers(model)
        return unless model
        
        self.register_selection_observer(model)
        self.register_model_observer(model)
        
        puts "[Civiscope ObserverManager] 核心观察者已全部注册"
      end
      
      # ==========================================
      # 附加实体观察者
      # ==========================================
      def self.attach_entity_observers(entity)
        return unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        
        # 附加 EntityObserver 到实例（用于缩放/变换）
        id_str = CiviscopeLayout::Core.get_short_id(entity)
        unless @entity_observers[id_str]
          obs = EntityWatcher.new
          entity.add_observer(obs)
          @entity_observers[id_str] = obs
        end
        
        # 附加 EntitiesObserver 到定义（用于推拉/几何内容）
        definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
        unless @def_entities_observers[definition.guid]
          obs = BimEntitiesWatcher.new(definition)
          definition.entities.add_observer(obs)
          @def_entities_observers[definition.guid] = obs
        end
      end
      
      # ==========================================
      # 获取观察者状态（用于调试）
      # ==========================================
      def self.get_observer_status
        {
          entity_observers: @entity_observers.keys.length,
          def_entities_observers: @def_entities_observers.keys.length,
          selection_observer: @selection_observer ? "已注册" : "未注册",
          model_observer: @model_observer ? "已注册" : "未注册"
        }
      end
      
    end
  end
end