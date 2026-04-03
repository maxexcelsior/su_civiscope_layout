# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.get_active_targets(sel)
      model = Sketchup.active_model
      @nested_bp_warning = false
      
      if model.active_path && !model.active_path.empty?
        model.active_path.reverse.each do |inst|
          if inst.get_attribute("dynamic_attributes", "bldg_func") || inst.get_attribute("dynamic_attributes", "site_func")
            return [inst] 
          end
        end
      end
      
      processed_targets = []
      sel.each do |ent|
        if ent.is_a?(Sketchup::Face)
          processed_targets << ent
          next
        end
        next unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        
        is_bldg = ent.get_attribute("dynamic_attributes", "bldg_func")
        is_site = ent.get_attribute("dynamic_attributes", "site_func")
        
        if is_bldg || is_site
          processed_targets << ent
        else
          inner_cim = self.collect_cim_entities(ent)
          if inner_cim.any?
            @nested_bp_warning = true if self.detect_nesting?(ent)
            site = inner_cim.find { |e| e.get_attribute("dynamic_attributes", "site_func") }
            if site
              processed_targets << site
            else
              processed_targets += inner_cim.select { |e| e.get_attribute("dynamic_attributes", "bldg_func") }
            end
          else
            processed_targets << ent
          end
        end
      end
      processed_targets.uniq
    end

    def self.collect_cim_entities(container)
      results = []
      definition = container.is_a?(Sketchup::Group) ? container.definition : container.definition
      definition.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        if e.get_attribute("dynamic_attributes", "bldg_func") || e.get_attribute("dynamic_attributes", "site_func")
          results << e
        end
      end
      results
    end

    def self.detect_nesting?(container)
      definition = container.is_a?(Sketchup::Group) ? container.definition : container.definition
      definition.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        inner = self.collect_cim_entities(e)
        return true if inner.any?
      end
      false
    end

    def self.find_buildings_on_site(site)
      model = Sketchup.active_model
      all_bldgs = []
      
      # 1. First, check siblings (most common for BP Groups)
      if site.parent && site.parent.respond_to?(:entities)
        site.parent.entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          all_bldgs << e if e.get_attribute("dynamic_attributes", "bldg_func")
        end
      end
      
      # 2. Also check model root (just in case)
      model.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        next if all_bldgs.include?(e)
        all_bldgs << e if e.get_attribute("dynamic_attributes", "bldg_func")
      end

      # Filter by proximity / containment
      on_site_ents = []
      all_bldgs.each do |bldg|
        b_tr = CiviscopeLayout::Core.get_full_world_transform(bldg)
        local_bottom_center = Geom::Point3d.new(bldg.definition.bounds.center.x, bldg.definition.bounds.center.y, bldg.definition.bounds.min.z)
        world_bottom_center = local_bottom_center.transform(b_tr)
        
        if self.point_in_site_vertical?(world_bottom_center, site)
          on_site_ents << bldg
        end
      end
      on_site_ents
    end

    def self.format_bldg_data(entities)
      entities.map do |b|
        {
          id: self.get_short_id(b),
          no: b.get_attribute("dynamic_attributes", "bldg_no") || "",
          f: b.get_attribute("dynamic_attributes", "bldg_func") || "",
          area: b.get_attribute("dynamic_attributes", "bldg_area").to_f.round(2),
          base_area: b.get_attribute("dynamic_attributes", "base_area").to_f.round(2)
        }
      end
    end

    def self.calc_site_data(entity, skip_operation = false)
      # Implementation if needed, currently site area is often from dynamic attributes
      # placeholder if you ever add automatic site area calculation
    end

    def self.auto_recalculate(entity, skip_ui_refresh = false, skip_operation = false)
      return unless entity.valid?
      
      if entity.get_attribute("dynamic_attributes", "bldg_func")
        bldg_func = entity.get_attribute("dynamic_attributes", "bldg_func")
        self.apply_material(entity, bldg_func)
        self.calc_bldg_data(entity, skip_operation)
        
        if @overlay && @overlay.respond_to?(:sites_data)
          @overlay.sites_data.keys.each do |site_id|
            site = Sketchup.active_model.find_entity_by_persistent_id(site_id.to_i)
            site ||= Sketchup.active_model.entities.to_a.find { |e| self.get_short_id(e) == site_id }
            if site
              bldgs = self.find_buildings_on_site(site)
              if bldgs.any? { |b| self.get_short_id(b) == self.get_short_id(entity) }
                self.update_overlay_state(site_id)
                UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
              end
            end
          end
        end
      elsif entity.get_attribute("dynamic_attributes", "site_func")
        site_func = entity.get_attribute("dynamic_attributes", "site_func")
        site_type = entity.get_attribute("dynamic_attributes", "site_type") || site_func
        self.apply_material(entity, site_func, site_type)
        self.calc_site_data(entity, skip_operation)
        
        id_str = self.get_short_id(entity)
        if @overlay && @overlay.sites_data.key?(id_str)
          self.update_overlay_state(id_str)
          Sketchup.active_model.active_view.refresh
        end
      end
      
      self.refresh_stats_ui(Sketchup.active_model.selection) unless skip_ui_refresh
    end

    def self.calculate_site_metrics(site_entity, bldg_entities)
      total_gfa = 0.0
      deduplicated_base_area = 0.0
      green_area = 0.0
      
      # 1. Calc GFA (always sum all)
      bldg_entities.each do |b|
        total_gfa += b.get_attribute("dynamic_attributes", "bldg_area").to_f
      end
      
      # 2. Calc Footprint with Nesting Check
      sorted_bldgs = bldg_entities.sort_by { |b| b.get_attribute("dynamic_attributes", "base_area").to_f }.reverse
      sorted_bldgs.each_with_index do |child, i|
        is_nested = false
        child_area = child.get_attribute("dynamic_attributes", "base_area").to_f
        sorted_bldgs.each_with_index do |parent, j|
          next if i == j
          parent_area = parent.get_attribute("dynamic_attributes", "base_area").to_f
          next if parent_area < child_area - 0.1
          if CiviscopeLayout::Core.is_bldg_nested?(child, parent)
            is_nested = true; break
          end
        end
        deduplicated_base_area += child_area unless is_nested
      end

      # 3. Calc Green Area (Recursive scan for material)
      if site_entity && site_entity.valid?
        green_mat_name = "Civiscope_内部绿地"
        model = Sketchup.active_model
        target_mat = model.materials[green_mat_name]
        
        green_area_sq_ins = 0.0
        if target_mat
          entities = site_entity.is_a?(Sketchup::Group) ? site_entity.definition.entities : site_entity.definition.entities
          green_area_sq_ins = self.sum_green_area(entities, target_mat)
        end
        green_area = green_area_sq_ins * (0.0254 ** 2)
      end
      
      [total_gfa.round(2), deduplicated_base_area.round(2), green_area.round(2)]
    end

    def self.sum_green_area(entities, target_mat, inherited_mat = nil)
      area_sum = 0.0
      entities.each do |ent|
        # Determine effective material (local or inherited)
        current_mat = ent.material || inherited_mat
        
        if ent.is_a?(Sketchup::Face)
          # Only count if the effective material matches the target
          if current_mat == target_mat
            area_sum += ent.area
          end
        elsif ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
          # Recursive scan for sub-entities with inherited material
          definition = ent.is_a?(Sketchup::Group) ? ent.definition : ent.definition
          area_sum += self.sum_green_area(definition.entities, target_mat, current_mat)
        end
      end
      area_sum
    end

  end
end
