import { Column, Entity, JoinColumn, OneToMany, OneToOne, PrimaryColumn } from 'typeorm';
import { AssetEntity } from './asset.entity';

@Entity('asset_stack')
export class AssetStackEntity {
  @PrimaryColumn()
  id!: string;

  @OneToMany(() => AssetEntity, (asset) => asset.stack)
  @JoinColumn()
  asset!: AssetEntity;

  @Column()
  assetId!: string;

  @OneToOne(() => AssetEntity)
  @JoinColumn()
  parent!: AssetEntity;
}
